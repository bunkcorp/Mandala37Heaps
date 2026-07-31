#include <metal_stdlib>
using namespace metal;

constant uint kEmpty = 0xFFFFFFFFu;
constant uint kMaxNeighborsPerCell = 48u;

// state: 0 inactive, 1 active, 2 settled surface, 3 buried sleep
struct GrainParticle {
    float3 position;
    float3 velocity;
    float radius;
    float mass;
    uint state;
    uint pad;
};

struct GrainUniforms {
    float dt;
    float gravityY;
    float fillRadius;
    float maxHeight;
    float cellSize;
    float reposeTan;
    float settleSpeed;
    float depositScale;
    uint gridRes;
    uint particleCount;
    float hashCellSize;
    uint hashResXZ;
    uint hashResY;
    float demStiffness;
    float demDamping;
    float demFriction;
    float wakeImpulse;
    float sleepDepth; // meters below pack surface → state 3
};

struct MeshVertex {
    float3 position;
    float3 normal;
    float4 color;
};

struct PourParams {
    float3 center;      // xz used; y = surface emit base
    float radius;
    uint startSlot;
    uint count;
    uint particleCount;
    uint pad0;
};

static inline uint heightCellIndex(float2 xz, float fillRadius, float cellSize, uint gridRes) {
    float2 local = xz + float2(fillRadius, fillRadius);
    int x = clamp(int(local.x / cellSize), 0, int(gridRes) - 1);
    int z = clamp(int(local.y / cellSize), 0, int(gridRes) - 1);
    return uint(z * int(gridRes) + x);
}

static inline float sampleHeight(device const uint *heightField, float2 xz,
                                 float fillRadius, float cellSize, uint gridRes) {
    uint idx = heightCellIndex(xz, fillRadius, cellSize, gridRes);
    return float(heightField[idx]) * 1.0e-6;
}

static inline int3 hashCoord(float3 p, constant GrainUniforms &u) {
    float2 origin = float2(-u.fillRadius, -u.fillRadius);
    int x = clamp(int((p.x - origin.x) / u.hashCellSize), 0, int(u.hashResXZ) - 1);
    int y = clamp(int(p.y / u.hashCellSize), 0, int(u.hashResY) - 1);
    int z = clamp(int((p.z - origin.y) / u.hashCellSize), 0, int(u.hashResXZ) - 1);
    return int3(x, y, z);
}

static inline uint hashIndex(int3 c, constant GrainUniforms &u) {
    return uint(c.y) * (u.hashResXZ * u.hashResXZ) + uint(c.z) * u.hashResXZ + uint(c.x);
}

// MARK: - Integrate

kernel void integrateGrains(
    device GrainParticle *particles [[buffer(0)]],
    device const uint *heightField [[buffer(1)]],
    constant GrainUniforms &u [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) { return; }
    GrainParticle p = particles[id];
    if (p.state == 0 || p.state == 3) { return; } // inactive / buried sleep

    if (p.state == 2) {
        float h = sampleHeight(heightField, p.position.xz, u.fillRadius, u.cellSize, u.gridRes);
        p.position.y = max(p.position.y, h + p.radius * 0.85);
        p.velocity *= 0.4;
        particles[id] = p;
        return;
    }

    p.velocity.y += u.gravityY * u.dt;
    p.velocity *= 0.994;
    p.position += p.velocity * u.dt;

    float2 xz = p.position.xz;
    float radial = length(xz);
    float maxR = max(u.fillRadius - p.radius * 2.0, 0.01);
    if (radial > maxR) {
        float2 n = xz / max(radial, 1e-5);
        p.position.xz = n * maxR;
        float vn = dot(p.velocity.xz, n);
        if (vn > 0.0) {
            p.velocity.xz -= n * vn * 1.4;
        }
        p.velocity.xz *= 0.7;
    }

    float h = sampleHeight(heightField, p.position.xz, u.fillRadius, u.cellSize, u.gridRes);
    float floorY = h + p.radius;
    if (p.position.y < floorY) {
        p.position.y = floorY;
        if (p.velocity.y < 0.0) {
            p.velocity.y *= -0.06;
        }
        p.velocity.xz *= 0.78;
    }

    float rim = u.maxHeight - p.radius;
    if (p.position.y > rim) {
        p.position.y = rim;
        p.velocity.y = min(p.velocity.y, 0.0);
    }

    particles[id] = p;
}

/// Deeply buried settled grains leave the DEM hash entirely.
kernel void sleepBuriedGrains(
    device GrainParticle *particles [[buffer(0)]],
    device const uint *heightField [[buffer(1)]],
    constant GrainUniforms &u [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) { return; }
    GrainParticle p = particles[id];
    if (p.state != 2) { return; }

    float h = sampleHeight(heightField, p.position.xz, u.fillRadius, u.cellSize, u.gridRes);
    if (p.position.y < h - u.sleepDepth) {
        p.state = 3;
        p.velocity = float3(0.0);
        particles[id] = p;
    }
}

// MARK: - Spatial hash + DEM

kernel void clearHashHeads(
    device atomic_uint *cellHeads [[buffer(0)]],
    constant GrainUniforms &u [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    uint cellCount = u.hashResY * u.hashResXZ * u.hashResXZ;
    if (id >= cellCount) { return; }
    atomic_store_explicit(&cellHeads[id], kEmpty, memory_order_relaxed);
}

kernel void insertHash(
    device GrainParticle *particles [[buffer(0)]],
    device atomic_uint *cellHeads [[buffer(1)]],
    device uint *nextIndex [[buffer(2)]],
    constant GrainUniforms &u [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) { return; }
    GrainParticle p = particles[id];
    nextIndex[id] = kEmpty;
    // Only active + surface settled participate in DEM neighborhood queries.
    if (p.state != 1 && p.state != 2) { return; }

    int3 c = hashCoord(p.position, u);
    uint cell = hashIndex(c, u);
    uint prev = atomic_exchange_explicit(&cellHeads[cell], id, memory_order_relaxed);
    nextIndex[id] = prev;
}

kernel void demContacts(
    device GrainParticle *particles [[buffer(0)]],
    device const atomic_uint *cellHeads [[buffer(1)]],
    device const uint *nextIndex [[buffer(2)]],
    constant GrainUniforms &u [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) { return; }
    GrainParticle p = particles[id];
    if (p.state != 1) { return; }

    int3 c0 = hashCoord(p.position, u);
    float3 force = float3(0.0);
    float3 posCorrection = float3(0.0);
    uint contacts = 0;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dz = -1; dz <= 1; ++dz) {
            for (int dx = -1; dx <= 1; ++dx) {
                int3 c = c0 + int3(dx, dy, dz);
                if (c.x < 0 || c.y < 0 || c.z < 0 ||
                    c.x >= int(u.hashResXZ) || c.y >= int(u.hashResY) || c.z >= int(u.hashResXZ)) {
                    continue;
                }
                uint cell = hashIndex(c, u);
                uint j = atomic_load_explicit(&cellHeads[cell], memory_order_relaxed);
                uint guard = 0;
                while (j != kEmpty && guard < kMaxNeighborsPerCell) {
                    ++guard;
                    if (j != id) {
                        GrainParticle q = particles[j];
                        if (q.state == 1 || q.state == 2) {
                            float3 delta = p.position - q.position;
                            float dist = length(delta);
                            float minDist = p.radius + q.radius;
                            if (dist < minDist && dist > 1e-6) {
                                float3 n = delta / dist;
                                float overlap = minDist - dist;
                                float3 vrel = p.velocity - q.velocity;
                                float vn = dot(vrel, n);
                                float3 fn = n * (u.demStiffness * overlap - u.demDamping * vn);
                                float3 vt = vrel - n * vn;
                                float3 ft = -u.demFriction * vt;
                                force += fn + ft;
                                posCorrection += n * (overlap * (q.state == 2 ? 1.0 : 0.5) * 0.55);
                                contacts += 1;
                            }
                        }
                    }
                    j = nextIndex[j];
                }
            }
        }
    }

    if (contacts > 0) {
        p.velocity += (force / max(p.mass, 0.001)) * u.dt;
        p.position += posCorrection;
        float speed = length(p.velocity);
        if (speed > 1.8) {
            p.velocity *= 1.8 / speed;
        }
    }
    particles[id] = p;
}

kernel void wakeAvalancheCandidates(
    device GrainParticle *particles [[buffer(0)]],
    device const uint *heightField [[buffer(1)]],
    device const atomic_uint *cellHeads [[buffer(2)]],
    device const uint *nextIndex [[buffer(3)]],
    constant GrainUniforms &u [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) { return; }
    GrainParticle p = particles[id];
    if (p.state != 2) { return; }

    float h = sampleHeight(heightField, p.position.xz, u.fillRadius, u.cellSize, u.gridRes);
    if (p.position.y < h - p.radius * 1.5) { return; }

    bool wake = false;
    int3 c0 = hashCoord(p.position, u);
    for (int dy = -1; dy <= 1 && !wake; ++dy) {
        for (int dz = -1; dz <= 1 && !wake; ++dz) {
            for (int dx = -1; dx <= 1 && !wake; ++dx) {
                int3 c = c0 + int3(dx, dy, dz);
                if (c.x < 0 || c.y < 0 || c.z < 0 ||
                    c.x >= int(u.hashResXZ) || c.y >= int(u.hashResY) || c.z >= int(u.hashResXZ)) {
                    continue;
                }
                uint cell = hashIndex(c, u);
                uint j = atomic_load_explicit(&cellHeads[cell], memory_order_relaxed);
                uint guard = 0;
                while (j != kEmpty && guard < kMaxNeighborsPerCell) {
                    ++guard;
                    if (j != id) {
                        GrainParticle q = particles[j];
                        if (q.state == 1) {
                            float dist = distance(p.position, q.position);
                            float minDist = p.radius + q.radius;
                            if (dist < minDist * 0.92) {
                                wake = true;
                                break;
                            }
                        }
                    }
                    j = nextIndex[j];
                }
            }
        }
    }

    if (!wake) {
        uint res = u.gridRes;
        uint idx = heightCellIndex(p.position.xz, u.fillRadius, u.cellSize, res);
        uint x = idx % res;
        uint z = idx / res;
        float h0 = float(heightField[idx]) * 1.0e-6;
        float maxDiff = 0.0;
        if (x + 1 < res) { maxDiff = max(maxDiff, abs(h0 - float(heightField[z * res + x + 1]) * 1.0e-6)); }
        if (x > 0) { maxDiff = max(maxDiff, abs(h0 - float(heightField[z * res + x - 1]) * 1.0e-6)); }
        if (z + 1 < res) { maxDiff = max(maxDiff, abs(h0 - float(heightField[(z + 1) * res + x]) * 1.0e-6)); }
        if (z > 0) { maxDiff = max(maxDiff, abs(h0 - float(heightField[(z - 1) * res + x]) * 1.0e-6)); }
        if (maxDiff > u.cellSize * u.reposeTan * 1.15) {
            wake = true;
        }
    }

    if (wake) {
        p.state = 1;
        float2 outward = normalize(p.position.xz + float2(1e-4));
        p.velocity += float3(outward.x, 0.08, outward.y) * u.wakeImpulse;
        particles[id] = p;
    }
}

// MARK: - Height field

kernel void depositGrains(
    device GrainParticle *particles [[buffer(0)]],
    device atomic_uint *heightField [[buffer(1)]],
    constant GrainUniforms &u [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) { return; }
    GrainParticle p = particles[id];
    if (p.state != 1) { return; }

    float speed = length(p.velocity);
    uint idx = heightCellIndex(p.position.xz, u.fillRadius, u.cellSize, u.gridRes);
    float h = float(atomic_load_explicit(&heightField[idx], memory_order_relaxed)) * 1.0e-6;
    bool onSurface = p.position.y <= h + p.radius * 2.2;

    if (speed < u.settleSpeed && onSurface) {
        uint add = uint(max(p.radius * 2.0 * u.depositScale * 1.0e6, 1.0));
        atomic_fetch_add_explicit(&heightField[idx], add, memory_order_relaxed);
        p.state = 2;
        p.velocity = float3(0.0);
        particles[id] = p;
    }
}

kernel void relaxHeightField(
    device uint *heightField [[buffer(0)]],
    constant GrainUniforms &u [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    uint n = u.gridRes * u.gridRes;
    if (id >= n) { return; }

    uint x = id % u.gridRes;
    uint z = id / u.gridRes;
    float h = float(heightField[id]) * 1.0e-6;
    float maxDiff = u.cellSize * u.reposeTan;
    float target = h;

    const int2 nbrs[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    for (int i = 0; i < 4; ++i) {
        int nx = int(x) + nbrs[i].x;
        int nz = int(z) + nbrs[i].y;
        if (nx < 0 || nz < 0 || nx >= int(u.gridRes) || nz >= int(u.gridRes)) { continue; }
        uint nidx = uint(nz) * u.gridRes + uint(nx);
        float nh = float(heightField[nidx]) * 1.0e-6;
        float diff = h - nh;
        if (diff > maxDiff) {
            target -= (diff - maxDiff) * 0.28;
        }
    }

    target = clamp(target, 0.0, u.maxHeight);
    heightField[id] = uint(target * 1.0e6);
}

kernel void addPulse(
    device atomic_uint *heightField [[buffer(0)]],
    constant GrainUniforms &u [[buffer(1)]],
    constant float4 &pulse [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    uint n = u.gridRes * u.gridRes;
    if (id >= n) { return; }

    uint x = id % u.gridRes;
    uint z = id / u.gridRes;
    float2 world = float2(float(x) + 0.5, float(z) + 0.5) * u.cellSize - float2(u.fillRadius, u.fillRadius);
    float d = distance(world, pulse.xy);
    if (d > pulse.z) { return; }

    float w = 1.0 - (d / max(pulse.z, 1e-4));
    w = w * w;
    uint add = uint(max(pulse.w * w * 1.0e6, 0.0));
    if (add > 0) {
        atomic_fetch_add_explicit(&heightField[id], add, memory_order_relaxed);
    }
}

kernel void raiseHeightFloor(
    device uint *heightField [[buffer(0)]],
    constant GrainUniforms &u [[buffer(1)]],
    constant uint &floorMicrons [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    uint n = u.gridRes * u.gridRes;
    if (id >= n) { return; }
    heightField[id] = max(heightField[id], floorMicrons);
}

kernel void compressHeightField(
    device uint *heightField [[buffer(0)]],
    constant GrainUniforms &u [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    uint n = u.gridRes * u.gridRes;
    if (id >= n) { return; }
    float h = float(heightField[id]) * 1.0e-6;
    // Stronger pack sink when the next ring presses in.
    heightField[id] = uint(max(0.0, h * 0.90 - 0.0045) * 1.0e6);
}

/// Hand / scoop disturber — wakes and pushes grains near a tool sphere (tier-local).
kernel void disturbWithTool(
    device GrainParticle *particles [[buffer(0)]],
    device const uint *heightField [[buffer(1)]],
    constant GrainUniforms &u [[buffer(2)]],
    constant float4 &tool [[buffer(3)]], // xyz = center, w = radius
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) { return; }
    GrainParticle p = particles[id];
    if (p.state == 0) { return; }

    float3 delta = p.position - tool.xyz;
    float dist = length(delta);
    float reach = tool.w + p.radius;
    if (dist > reach || dist < 1e-5) { return; }

    float h = sampleHeight(heightField, p.position.xz, u.fillRadius, u.cellSize, u.gridRes);
    // Ignore deeply buried sleepers.
    if (p.state == 3 && p.position.y < h - u.sleepDepth * 0.5) { return; }

    float3 n = delta / dist;
    float overlap = reach - dist;
    p.state = 1;
    p.velocity += n * (0.55 + overlap * 8.0);
    p.velocity.y += 0.12;
    p.position += n * (overlap * 0.45);
    particles[id] = p;
}

kernel void accumulateHeightSum(
    device const uint *heightField [[buffer(0)]],
    device atomic_uint *sumMicrons [[buffer(1)]],
    constant GrainUniforms &u [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    uint n = u.gridRes * u.gridRes;
    if (id >= n) { return; }
    atomic_fetch_add_explicit(sumMicrons, heightField[id], memory_order_relaxed);
}

kernel void compressWakeBand(
    device GrainParticle *particles [[buffer(0)]],
    device const uint *heightField [[buffer(1)]],
    constant GrainUniforms &u [[buffer(2)]],
    constant float4 &band [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) { return; }
    GrainParticle p = particles[id];
    if (p.state == 0) { return; }

    float r = length(p.position.xz);
    if (r < band.x || r > band.y) { return; }

    float h = sampleHeight(heightField, p.position.xz, u.fillRadius, u.cellSize, u.gridRes);
    // Wake surface settled + shallow buried sleepers in the annulus.
    if (p.position.y < h - 0.014) { return; }

    p.state = 1;
    p.position.y = max(0.0, p.position.y - band.z);
    float2 outward = normalize(p.position.xz + float2(1e-4));
    p.velocity += float3(outward.x * band.w, -0.05, outward.y * band.w);
    particles[id] = p;
}

// MARK: - GPU pour emit

kernel void emitPourBurst(
    device GrainParticle *particles [[buffer(0)]],
    constant PourParams &e [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= e.count) { return; }
    uint idx = (e.startSlot + id) % e.particleCount;

    float angle = float(id) * 2.39996323;
    float radial = sqrt(float(id) / float(max(e.count, 1u))) * e.radius;
    GrainParticle p;
    p.position = float3(
        e.center.x + cos(angle) * radial,
        e.center.y + 0.055 + float(id % 40u) * 0.0016,
        e.center.z + sin(angle) * radial
    );
    p.velocity = float3(
        sin(angle * 1.7) * 0.035,
        0.02,
        cos(angle * 1.3) * 0.035
    );
    p.radius = 0.0027 + float(id % 5u) * 0.00022;
    p.mass = 1.0;
    p.state = 1;
    p.pad = 0;
    particles[idx] = p;
}

// MARK: - GPU mesh builds (LowLevelMesh buffers)

kernel void buildHeightFieldMesh(
    device const uint *heightField [[buffer(0)]],
    device MeshVertex *vertices [[buffer(1)]],
    constant GrainUniforms &u [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    uint n = u.gridRes * u.gridRes;
    if (id >= n) { return; }

    uint x = id % u.gridRes;
    uint z = id / u.gridRes;
    float cell = u.cellSize;
    float fillR = u.fillRadius;
    float wx = float(x) * cell - fillR + cell * 0.5;
    float wz = float(z) * cell - fillR + cell * 0.5;
    float h = float(heightField[id]) * 1.0e-6;

    // Height field is stored on a square grid; clamp to the circular ring so
    // cream corners don't stick out past the metal fence as a flat square.
    float radial = length(float2(wx, wz));
    bool outside = radial > fillR;
    if (outside) {
        float2 dir = float2(wx, wz) / max(radial, 1e-5);
        wx = dir.x * fillR;
        wz = dir.y * fillR;
        h = 0.0;
    }

    uint xL = x > 0 ? x - 1 : 0;
    uint xR = min(x + 1, u.gridRes - 1);
    uint zD = z > 0 ? z - 1 : 0;
    uint zU = min(z + 1, u.gridRes - 1);
    float hL = float(heightField[z * u.gridRes + xL]) * 1.0e-6;
    float hR = float(heightField[z * u.gridRes + xR]) * 1.0e-6;
    float hD = float(heightField[zD * u.gridRes + x]) * 1.0e-6;
    float hU = float(heightField[zU * u.gridRes + x]) * 1.0e-6;
    float3 nrm = outside ? float3(0.0, 1.0, 0.0)
                         : normalize(float3(hL - hR, 2.0 * cell, hD - hU));

    MeshVertex v;
    v.position = float3(wx, h, wz);
    v.normal = nrm;
    v.color = float4(0.97, 0.95, 0.90, 1.0);
    vertices[id] = v;
}

kernel void buildParticleBillboards(
    device const GrainParticle *particles [[buffer(0)]],
    device MeshVertex *vertices [[buffer(1)]],
    device uint *indices [[buffer(2)]],
    device atomic_uint *outCount [[buffer(3)]],
    constant GrainUniforms &u [[buffer(4)]],
    constant uint &maxBillboards [[buffer(5)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) { return; }
    GrainParticle p = particles[id];
    if (p.state != 1) { return; }

    uint slot = atomic_fetch_add_explicit(outCount, 1u, memory_order_relaxed);
    if (slot >= maxBillboards) { return; }

    float3 c = p.position;
    float r = p.radius;
    float hx = r * 1.6;
    float hy = r * 0.9;
    float3 n = float3(0.0, 1.0, 0.0);
    float4 color = float4(0.99, 0.97, 0.93, 1.0);

    uint vi = slot * 4u;
    MeshVertex v0; v0.position = c + float3(-hx, 0.0, 0.0); v0.normal = n; v0.color = color;
    MeshVertex v1; v1.position = c + float3( hx, 0.0, 0.0); v1.normal = n; v1.color = color;
    MeshVertex v2; v2.position = c + float3( 0.0, hy, 0.0); v2.normal = n; v2.color = color;
    MeshVertex v3; v3.position = c + float3( 0.0, -hy * 0.2, 0.0); v3.normal = n; v3.color = color;
    vertices[vi + 0] = v0;
    vertices[vi + 1] = v1;
    vertices[vi + 2] = v2;
    vertices[vi + 3] = v3;

    uint ii = slot * 6u;
    uint base = vi;
    indices[ii + 0] = base;
    indices[ii + 1] = base + 2;
    indices[ii + 2] = base + 1;
    indices[ii + 3] = base;
    indices[ii + 4] = base + 1;
    indices[ii + 5] = base + 3;
}
