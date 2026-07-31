#include <metal_stdlib>
using namespace metal;

// Must match Swift `MPMParticle` (112 bytes).
struct MPMParticle {
    float4 xMass; // xyz, mass
    float4 vVol;  // xyz velocity, w volume0
    float F[9];   // column-major
    float C[9];   // column-major
    uint state;   // 0 empty, 1 active, 2 sleep
    float Jp;
};

// Must match Swift `MPMUniforms`.
struct MPMUniforms {
    float dt;
    float dx;
    float invDx;
    float gravityY;
    float originX;
    float originY;
    float originZ;
    float fillRadius;
    float plateY;
    float maxHeight;
    uint nx;
    uint ny;
    uint nz;
    uint particleCount;
    float density;
    float youngs;
    float poisson;
    float alphaFriction;
    float cohesion;
    float capPressure;
    float sleepDepth;
    uint capsuleCount;
};

struct MPMCapsule {
    float4 p0r; // xyz + radius
    float4 p1;  // xyz + pad
};

struct MPMDiagnostics {
    atomic_uint activeCount;
    atomic_uint sleepCount;
    atomic_float massSum;
    atomic_float momX;
    atomic_float momY;
    atomic_float momZ;
    atomic_uint maxPenetrationU; // micrometers
    atomic_uint yieldViolations;
};

inline float3 particleX(MPMParticle p) { return p.xMass.xyz; }
inline float particleMass(MPMParticle p) { return p.xMass.w; }
inline float3 particleV(MPMParticle p) { return p.vVol.xyz; }
inline float particleVol0(MPMParticle p) { return p.vVol.w; }

inline float3x3 matFromArr(const float m[9]) {
    return float3x3(
        float3(m[0], m[1], m[2]),
        float3(m[3], m[4], m[5]),
        float3(m[6], m[7], m[8])
    );
}

inline void matToArr(float3x3 M, thread float out[9]) {
    out[0] = M[0][0]; out[1] = M[0][1]; out[2] = M[0][2];
    out[3] = M[1][0]; out[4] = M[1][1]; out[5] = M[1][2];
    out[6] = M[2][0]; out[7] = M[2][1]; out[8] = M[2][2];
}

inline float3x3 matIdentity() {
    return float3x3(float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1));
}

inline float matDet(float3x3 m) {
    return determinant(m);
}

inline float3x3 matTranspose(float3x3 m) { return transpose(m); }

inline float frobenius(float3x3 m) {
    float s = 0;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j)
            s += m[i][j] * m[i][j];
    return sqrt(s);
}

/// Quadratic B-spline weight and gradient (MLS-MPM / APIC).
inline void quadraticWeights(float fx, thread float w[3], thread float dw[3]) {
    // N2 basis relative to base node (floor(x/dx)-1).
    float x = fx - floor(fx);
    w[0] = 0.5 * (1.5 - x) * (1.5 - x);
    w[1] = 0.75 - (x - 1.0) * (x - 1.0);
    w[2] = 0.5 * (x - 0.5) * (x - 0.5);
    dw[0] = x - 1.5;
    dw[1] = -2.0 * (x - 1.0);
    dw[2] = x - 0.5;
}

inline int nodeIndex(int i, int j, int k, uint nx, uint ny, uint nz) {
    i = clamp(i, 0, int(nx) - 1);
    j = clamp(j, 0, int(ny) - 1);
    k = clamp(k, 0, int(nz) - 1);
    return i + int(nx) * (j + int(ny) * k);
}

inline float capsuleSDF(float3 x, MPMCapsule c) {
    float3 a = c.p0r.xyz;
    float3 b = c.p1.xyz;
    float r = c.p0r.w;
    float3 pa = x - a;
    float3 ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
    return length(pa - ba * h) - r;
}

inline bool finite3(float3 v) {
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z);
}

inline float3 clampVec(float3 v, float lim) {
    float n = length(v);
    if (!isfinite(n) || n > lim) {
        if (n < 1e-12 || !isfinite(n)) return float3(0);
        return v * (lim / n);
    }
    return v;
}

inline float3x3 sanitizeF(float3x3 F) {
    float J = matDet(F);
    float fr = frobenius(F);
    if (!isfinite(J) || !isfinite(fr) || J < 0.08 || J > 4.0 || fr > 8.0) {
        return matIdentity();
    }
    return F;
}

inline float3x3 clampMat(float3x3 M, float lim) {
    float3x3 out = M;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            float a = out[i][j];
            if (!isfinite(a)) a = 0;
            out[i][j] = clamp(a, -lim, lim);
        }
    }
    return out;
}

/// Kirchhoff stress from elastic F via fixed-corotated + volumetric term (simplified).
inline float3x3 kirchhoffStress(float3x3 F, float mu, float lambda) {
    // τ = μ (F F^T − I) + λ log(J) I  (isotropic Hencky-ish)
    F = sanitizeF(F);
    float J = clamp(matDet(F), 0.08, 4.0);
    float3x3 b = F * matTranspose(F);
    float3x3 I = matIdentity();
    float logJ = log(J);
    float3x3 tau = mu * (b - I) + lambda * logJ * I;
    return clampMat(tau, 5.0e5);
}

/// Drucker–Prager return on Kirchhoff stress; updates F toward plastic correction via Jp.
inline float3x3 returnMapDP(
    float3x3 F,
    thread float &Jp,
    float mu,
    float lambda,
    float alpha,
    float cohesion,
    float capPressure,
    thread uint &yieldHit
) {
    float3x3 stress = kirchhoffStress(F, mu, lambda);
    // Pressure p = −tr(τ)/3, von Mises q.
    float tr = stress[0][0] + stress[1][1] + stress[2][2];
    float p = -tr / 3.0;
    float3x3 s = stress + (p) * matIdentity(); // deviatoric with sign: τ_dev = τ + p I
    float j2 = 0.5 * frobenius(s) * frobenius(s);
    float q = sqrt(max(2.0 * j2, 0.0));

    // Cap: limit compression.
    if (p > capPressure) {
        float scale = capPressure / max(p, 1e-6);
        // Soften volumetric part of F via Jp.
        Jp *= (1.0 + 0.02 * (1.0 - scale));
        Jp = clamp(Jp, 0.6, 1.4);
        yieldHit = 1;
    }

    float yield = q + alpha * p - cohesion;
    if (yield > 0.0 && q > 1e-8) {
        // Project q back onto cone.
        float qNew = max(0.0, -alpha * p + cohesion);
        float scale = qNew / q;
        s = s * scale;
        stress = s - p * matIdentity();
        // Plastic volume update (dilation/compaction hint).
        Jp = Jp * (1.0 - 0.01 * saturate(yield / (q + 1.0)));
        Jp = clamp(Jp, 0.6, 1.4);
        yieldHit = 1;

        // Pull F toward lower elastic strain.
        float soften = 1.0 - 0.08 * saturate(yield / (mu + 1.0));
        F = F * soften;
        // Restore volume ~ Jp
        float J = max(matDet(F), 1e-6);
        float targetJ = Jp;
        F = F * pow(targetJ / J, 1.0 / 3.0);
    }
    return F;
}

kernel void mpmClearGrid(
    device atomic_float *gridMass [[buffer(0)]],
    device atomic_float *gridVx [[buffer(1)]],
    device atomic_float *gridVy [[buffer(2)]],
    device atomic_float *gridVz [[buffer(3)]],
    constant MPMUniforms &u [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    uint n = u.nx * u.ny * u.nz;
    if (id >= n) return;
    atomic_store_explicit(gridMass + id, 0.0f, memory_order_relaxed);
    atomic_store_explicit(gridVx + id, 0.0f, memory_order_relaxed);
    atomic_store_explicit(gridVy + id, 0.0f, memory_order_relaxed);
    atomic_store_explicit(gridVz + id, 0.0f, memory_order_relaxed);
}

kernel void mpmP2G(
    device MPMParticle *particles [[buffer(0)]],
    device atomic_float *gridMass [[buffer(1)]],
    device atomic_float *gridVx [[buffer(2)]],
    device atomic_float *gridVy [[buffer(3)]],
    device atomic_float *gridVz [[buffer(4)]],
    constant MPMUniforms &u [[buffer(5)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) return;
    MPMParticle p = particles[id];
    if (p.state != 1) return;

    float3 x = particleX(p);
    float mass = particleMass(p);
    float3 v = particleV(p);
    float V0 = particleVol0(p);
    if (!finite3(x) || !finite3(v) || !isfinite(mass) || mass <= 0 || !isfinite(V0) || V0 <= 0) {
        p.state = 0;
        particles[id] = p;
        return;
    }
    v = clampVec(v, 4.0);

    float3x3 F = sanitizeF(matFromArr(p.F));
    float3x3 C = clampMat(matFromArr(p.C), 80.0);

    float youngs = clamp(u.youngs, 1.0e4, 1.0e6);
    float poisson = clamp(u.poisson, 0.05, 0.45);
    float mu = youngs / (2.0 * (1.0 + poisson));
    float lambda = youngs * poisson / ((1.0 + poisson) * (1.0 - 2.0 * poisson));
    float3x3 stress = kirchhoffStress(F, mu, lambda);
    float J = clamp(matDet(F), 0.08, 4.0);
    float volume = V0 * J;

    float3 origin = float3(u.originX, u.originY, u.originZ);
    float3 gridX = (x - origin) * u.invDx;
    int base_i = int(floor(gridX.x)) - 1;
    int base_j = int(floor(gridX.y)) - 1;
    int base_k = int(floor(gridX.z)) - 1;

    float wx[3], wy[3], wz[3], dwx[3], dwy[3], dwz[3];
    quadraticWeights(gridX.x, wx, dwx);
    quadraticWeights(gridX.y, wy, dwy);
    quadraticWeights(gridX.z, wz, dwz);

    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            for (int k = 0; k < 3; ++k) {
                float w = wx[i] * wy[j] * wz[k];
                if (w < 1e-8) continue;
                float3 dweight = float3(dwx[i] * wy[j] * wz[k],
                                        wx[i] * dwy[j] * wz[k],
                                        wx[i] * wy[j] * dwz[k]) * u.invDx;

                int ni = base_i + i;
                int nj = base_j + j;
                int nk = base_k + k;
                int idx = nodeIndex(ni, nj, nk, u.nx, u.ny, u.nz);

                float3 nodePos = origin + float3(float(ni), float(nj), float(nk)) * u.dx;
                float3 affine = C * (nodePos - x);
                float3 mom = mass * (v + clampVec(affine, 4.0));
                // Stress divergence contribution (MLS-MPM), softened for realtime stability.
                float3 force = (u.dt * volume) * (stress * dweight);
                mom -= clampVec(force, mass * 8.0);

                if (!finite3(mom)) continue;
                atomic_fetch_add_explicit(gridMass + idx, w * mass, memory_order_relaxed);
                atomic_fetch_add_explicit(gridVx + idx, w * mom.x, memory_order_relaxed);
                atomic_fetch_add_explicit(gridVy + idx, w * mom.y, memory_order_relaxed);
                atomic_fetch_add_explicit(gridVz + idx, w * mom.z, memory_order_relaxed);
            }
        }
    }
}

kernel void mpmGridUpdate(
    device atomic_float *gridMass [[buffer(0)]],
    device atomic_float *gridVx [[buffer(1)]],
    device atomic_float *gridVy [[buffer(2)]],
    device atomic_float *gridVz [[buffer(3)]],
    constant MPMUniforms &u [[buffer(4)]],
    constant MPMCapsule *capsules [[buffer(5)]],
    device atomic_float *impulseX [[buffer(6)]],
    device atomic_float *impulseY [[buffer(7)]],
    device atomic_float *impulseZ [[buffer(8)]],
    device MPMDiagnostics *diag [[buffer(9)]],
    uint id [[thread_position_in_grid]]
) {
    uint n = u.nx * u.ny * u.nz;
    if (id >= n) return;

    float m = atomic_load_explicit(gridMass + id, memory_order_relaxed);
    if (m <= 1e-10) {
        atomic_store_explicit(gridVx + id, 0.0f, memory_order_relaxed);
        atomic_store_explicit(gridVy + id, 0.0f, memory_order_relaxed);
        atomic_store_explicit(gridVz + id, 0.0f, memory_order_relaxed);
        return;
    }

    float3 mom = float3(
        atomic_load_explicit(gridVx + id, memory_order_relaxed),
        atomic_load_explicit(gridVy + id, memory_order_relaxed),
        atomic_load_explicit(gridVz + id, memory_order_relaxed)
    );
    float3 vel = mom / m;
    if (!finite3(vel)) vel = float3(0);
    vel = clampVec(vel, 4.0);
    vel.y += u.gravityY * u.dt;

    uint nx = u.nx, ny = u.ny, nz = u.nz;
    int i = int(id % nx);
    int j = int((id / nx) % ny);
    int k = int(id / (nx * ny));
    float3 origin = float3(u.originX, u.originY, u.originZ);
    float3 pos = origin + float3(float(i), float(j), float(k)) * u.dx;

    // Plate floor.
    float pen = u.plateY - pos.y;
    if (pen > 0.0) {
        pos.y = u.plateY;
        if (vel.y < 0.0) vel.y *= -0.05;
        vel.x *= 0.85;
        vel.z *= 0.85;
        // Only report shallow contact penetrations (ignore far ghost cells).
        if (pen < 0.04) {
            atomic_fetch_max_explicit(&diag->maxPenetrationU, uint(pen * 1e6f), memory_order_relaxed);
        }
    }

    // Open ring wall (cylinder).
    float r = length(float2(pos.x, pos.z));
    float wallPen = r - u.fillRadius;
    // Square grid corners sit outside the ring; only contact a thin band.
    if (wallPen > 0.0 && wallPen < 2.5 * u.dx && pos.y < u.maxHeight + 0.02) {
        float2 n2 = normalize(float2(pos.x, pos.z) + float2(1e-6));
        float vn = vel.x * n2.x + vel.z * n2.y;
        if (vn > 0.0) {
            vel.x -= vn * n2.x;
            vel.z -= vn * n2.y;
        }
        pos.x -= wallPen * n2.x;
        pos.z -= wallPen * n2.y;
        atomic_fetch_max_explicit(&diag->maxPenetrationU, uint(wallPen * 1e6f), memory_order_relaxed);
        // Ring-foot impulse diagnostic (outward normal → reaction on ring).
        float3 impulse = float3(n2.x, 0, n2.y) * (m * max(vn, 0.0));
        if (finite3(impulse)) {
            atomic_fetch_add_explicit(impulseX, impulse.x, memory_order_relaxed);
            atomic_fetch_add_explicit(impulseY, impulse.y, memory_order_relaxed);
            atomic_fetch_add_explicit(impulseZ, impulse.z, memory_order_relaxed);
        }
    } else if (wallPen >= 2.5 * u.dx) {
        // Zero velocity outside the ring band so ghost momentum cannot recirculate.
        vel = float3(0);
    }

    // Kinematic tool / phalanx capsules.
    for (uint c = 0; c < u.capsuleCount; ++c) {
        float d = capsuleSDF(pos, capsules[c]);
        if (d < 0.0) {
            // Approximate normal via central differences.
            float e = 0.0015;
            float3 n = normalize(float3(
                capsuleSDF(pos + float3(e, 0, 0), capsules[c]) - capsuleSDF(pos - float3(e, 0, 0), capsules[c]),
                capsuleSDF(pos + float3(0, e, 0), capsules[c]) - capsuleSDF(pos - float3(0, e, 0), capsules[c]),
                capsuleSDF(pos + float3(0, 0, e), capsules[c]) - capsuleSDF(pos - float3(0, 0, e), capsules[c])
            ) + float3(1e-6));
            float vn = dot(vel, n);
            if (vn < 0.0) vel -= vn * n;
            pos -= d * n;
            atomic_fetch_max_explicit(&diag->maxPenetrationU, uint((-d) * 1e6f), memory_order_relaxed);
        }
    }

    // Domain padding sticky walls.
    if (i <= 1 && vel.x < 0) vel.x = 0;
    if (i >= int(nx) - 2 && vel.x > 0) vel.x = 0;
    if (j <= 1 && vel.y < 0) vel.y = 0;
    if (j >= int(ny) - 2 && vel.y > 0) vel.y = 0;
    if (k <= 1 && vel.z < 0) vel.z = 0;
    if (k >= int(nz) - 2 && vel.z > 0) vel.z = 0;

    atomic_store_explicit(gridVx + id, vel.x, memory_order_relaxed);
    atomic_store_explicit(gridVy + id, vel.y, memory_order_relaxed);
    atomic_store_explicit(gridVz + id, vel.z, memory_order_relaxed);
}

kernel void mpmG2P(
    device MPMParticle *particles [[buffer(0)]],
    device atomic_float *gridMass [[buffer(1)]],
    device atomic_float *gridVx [[buffer(2)]],
    device atomic_float *gridVy [[buffer(3)]],
    device atomic_float *gridVz [[buffer(4)]],
    constant MPMUniforms &u [[buffer(5)]],
    device MPMDiagnostics *diag [[buffer(6)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) return;
    MPMParticle p = particles[id];
    if (p.state == 0) return;
    if (p.state == 2) {
        // Sleeping particles stay put; still count mass.
        atomic_fetch_add_explicit(&diag->sleepCount, 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&diag->massSum, particleMass(p), memory_order_relaxed);
        return;
    }

    float3 x = particleX(p);
    float3 origin = float3(u.originX, u.originY, u.originZ);
    float3 gridX = (x - origin) * u.invDx;
    int base_i = int(floor(gridX.x)) - 1;
    int base_j = int(floor(gridX.y)) - 1;
    int base_k = int(floor(gridX.z)) - 1;

    float wx[3], wy[3], wz[3], dwx[3], dwy[3], dwz[3];
    quadraticWeights(gridX.x, wx, dwx);
    quadraticWeights(gridX.y, wy, dwy);
    quadraticWeights(gridX.z, wz, dwz);

    float3 newV = float3(0);
    float3x3 B = float3x3(0);

    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            for (int k = 0; k < 3; ++k) {
                float w = wx[i] * wy[j] * wz[k];
                if (w < 1e-8) continue;
                int ni = base_i + i;
                int nj = base_j + j;
                int nk = base_k + k;
                int idx = nodeIndex(ni, nj, nk, u.nx, u.ny, u.nz);
                float3 nodePos = origin + float3(float(ni), float(nj), float(nk)) * u.dx;
                float3 vel = float3(
                    atomic_load_explicit(gridVx + idx, memory_order_relaxed),
                    atomic_load_explicit(gridVy + idx, memory_order_relaxed),
                    atomic_load_explicit(gridVz + idx, memory_order_relaxed)
                );
                newV += w * vel;
                float3 dpos = nodePos - x;
                // APIC: B = Σ w v ⊗ dpos
                B += w * float3x3(
                    vel * dpos.x,
                    vel * dpos.y,
                    vel * dpos.z
                );
            }
        }
    }

    if (!finite3(newV)) newV = float3(0);
    newV = clampVec(newV, 4.0);

    // C = B * (4 / dx^2) for quadratic B-spline APIC.
    float scale = 4.0 * u.invDx * u.invDx;
    float3x3 C = clampMat(B * scale, 80.0);
    float3x3 F = sanitizeF(matFromArr(p.F));
    F = sanitizeF((matIdentity() + u.dt * C) * F);

    float youngs = clamp(u.youngs, 1.0e4, 1.0e6);
    float poisson = clamp(u.poisson, 0.05, 0.45);
    float mu = youngs / (2.0 * (1.0 + poisson));
    float lambda = youngs * poisson / ((1.0 + poisson) * (1.0 - 2.0 * poisson));
    uint yieldHit = 0;
    float Jp = clamp(p.Jp, 0.6, 1.4);
    if (!isfinite(Jp)) Jp = 1.0;
    float alpha = clamp(u.alphaFriction, 0.0, 1.5);
    F = sanitizeF(returnMapDP(F, Jp, mu, lambda, alpha, u.cohesion, u.capPressure, yieldHit));
    if (yieldHit != 0) {
        atomic_fetch_add_explicit(&diag->yieldViolations, 1u, memory_order_relaxed);
    }

    x += u.dt * newV;
    if (!finite3(x)) {
        p.state = 0;
        particles[id] = p;
        return;
    }

    // Clamp into ring + plate.
    x.y = max(x.y, u.plateY + 0.0005);
    x.y = min(x.y, u.maxHeight + 0.05);
    float r = length(float2(x.x, x.z));
    if (r > u.fillRadius * 0.995) {
        float2 n2 = normalize(float2(x.x, x.z) + float2(1e-6));
        x.x = n2.x * u.fillRadius * 0.995;
        x.z = n2.y * u.fillRadius * 0.995;
        float vn = newV.x * n2.x + newV.z * n2.y;
        if (vn > 0) {
            newV.x -= vn * n2.x;
            newV.z -= vn * n2.y;
        }
    }

    // Sleep deep below pack surface proxy (low speed near plate).
    if (length(newV) < 0.02 && x.y < u.plateY + u.sleepDepth) {
        p.state = 2;
        newV = float3(0);
        C = float3x3(0);
    }

    float mass = particleMass(p);
    if (!isfinite(mass) || mass <= 0) {
        p.state = 0;
        particles[id] = p;
        return;
    }

    p.xMass = float4(x, mass);
    p.vVol = float4(newV, particleVol0(p));
    matToArr(F, p.F);
    matToArr(C, p.C);
    p.Jp = Jp;
    particles[id] = p;

    atomic_fetch_add_explicit(&diag->activeCount, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&diag->massSum, mass, memory_order_relaxed);
    if (finite3(newV)) {
        atomic_fetch_add_explicit(&diag->momX, mass * newV.x, memory_order_relaxed);
        atomic_fetch_add_explicit(&diag->momY, mass * newV.y, memory_order_relaxed);
        atomic_fetch_add_explicit(&diag->momZ, mass * newV.z, memory_order_relaxed);
    }
}

kernel void mpmEmitPour(
    device MPMParticle *particles [[buffer(0)]],
    constant MPMUniforms &u [[buffer(1)]],
    constant float4 &centerCount [[buffer(2)]], // xyz center, w = count
    constant uint &startSlot [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    uint count = uint(centerCount.w);
    if (id >= count) return;
    uint slot = (startSlot + id) % u.particleCount;

    // Deterministic hash scatter.
    uint h = id * 1664525u + 1013904223u;
    float rx = float((h >> 0) & 1023) / 1023.0;
    float ry = float((h >> 10) & 1023) / 1023.0;
    float rz = float((h >> 20) & 1023) / 1023.0;

    float radius = 0.035;
    float3 center = centerCount.xyz;
    float3 offset = float3((rx - 0.5) * 2.0 * radius,
                           ry * 0.04 + 0.02,
                           (rz - 0.5) * 2.0 * radius);
    float3 x = center + offset;
    float dx = u.dx;
    float vol = dx * dx * dx;
    float mass = u.density * vol;

    MPMParticle p;
    p.xMass = float4(x, mass);
    p.vVol = float4(0.0, -0.35 - ry * 0.2, 0.0, vol);
    p.F[0] = 1; p.F[1] = 0; p.F[2] = 0;
    p.F[3] = 0; p.F[4] = 1; p.F[5] = 0;
    p.F[6] = 0; p.F[7] = 0; p.F[8] = 1;
    for (int i = 0; i < 9; ++i) p.C[i] = 0;
    p.state = 1;
    p.Jp = 1;
    particles[slot] = p;
}

/// Billboard vertices for active MPM particles (debug / presentation).
struct MPMVertex {
    float3 position;
    float3 normal;
    float4 color;
};

kernel void mpmBuildBillboards(
    device MPMParticle *particles [[buffer(0)]],
    device MPMVertex *vertices [[buffer(1)]],
    device uint *indices [[buffer(2)]],
    device atomic_uint *written [[buffer(3)]],
    constant MPMUniforms &u [[buffer(4)]],
    constant uint &maxBillboards [[buffer(5)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) return;
    MPMParticle p = particles[id];
    if (p.state == 0) return;

    uint slot = atomic_fetch_add_explicit(written, 1u, memory_order_relaxed);
    if (slot >= maxBillboards) return;

    float3 c = particleX(p);
    float s = u.dx * 0.35;
    float3 n = float3(0, 1, 0);
    float4 col = (p.state == 2)
        ? float4(0.72, 0.62, 0.42, 1)
        : float4(0.90, 0.78, 0.48, 1);

    uint vBase = slot * 4;
    vertices[vBase + 0] = { c + float3(-s, 0, -s), n, col };
    vertices[vBase + 1] = { c + float3( s, 0, -s), n, col };
    vertices[vBase + 2] = { c + float3( s, 0,  s), n, col };
    vertices[vBase + 3] = { c + float3(-s, 0,  s), n, col };

    uint iBase = slot * 6;
    indices[iBase + 0] = vBase + 0;
    indices[iBase + 1] = vBase + 1;
    indices[iBase + 2] = vBase + 2;
    indices[iBase + 3] = vBase + 0;
    indices[iBase + 4] = vBase + 2;
    indices[iBase + 5] = vBase + 3;
}
