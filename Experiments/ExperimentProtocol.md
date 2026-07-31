# Granular Experiment Protocol

Protocols for comparing the digital twin against physical rice (lab) and synthetic ground truth (in-app).

## Shared logging

Each run should log JSON lines (or a single JSON file) with:

- `experiment_id`, `solver` (`dem` | `mpmActive`)
- constitutive parameters (`phi_deg`, `cohesion`, `psi_deg`, `density`)
- timestamps, particle count, grid `dx`
- conservation: `mass_drift`, `momentum_residual`, `max_penetration`
- outcome metrics listed per experiment

App hook: `AppModel.exportDiagnosticsSnapshot()` (debug).

---

## 1. Angle-of-repose test

**Physical:** Pour a known mass through a fixed funnel onto a plate; measure final cone slope.

**In-app synthetic:** Emit a centered pour burst with no ring wall (or large fill radius); wait until kinetic energy < threshold; fit a cone to the surface height field / MPM surface.

**Metrics:**

- Repose angle (degrees)
- Final pile height / base radius
- Surface Chamfer distance vs reference mesh (synthetic)

**Pass band (default rice params):** repose ≈ 30°–38°.

---

## 2. Ring-lift collapse

**Physical:** Fill a ring, compact lightly, lift vertically; record collapse video.

**In-app:** Fill MPM/DEM inside ring SDF; remove / raise ring boundary; measure time-to-collapse and final footprint.

**Metrics:**

- Collapse onset time
- Final spread radius
- Mass remaining in original footprint
- Avalanche probability map (later Bayesian phase)

---

## 3. Scoop / blade intrusion

**Physical:** Push a flat tool through rice; measure force–displacement if instrumented.

**In-app:** Drive kinematic scoop SDF through packed material; integrate contact impulse magnitude vs depth.

**Metrics:**

- Peak contact impulse
- Impulse–depth RMSE vs reference curve (synthetic or lab)
- Max penetration of tool SDF

---

## 4. Additional lab tests (offline)

| Test | Purpose |
|------|---------|
| Tilt-table | Failure onset vs plate angle |
| Compaction | Volume change under known load |
| Discharge | Flow through openings of different diameters |

## Comparison metrics summary

- Surface Chamfer distance
- Earth mover’s distance (optional)
- Avalanche onset error
- Collapse-time error
- Force-curve RMSE
- Final-volume error
- Mass-conservation error \(\epsilon_M\)

---

## Phase 2 — Constitutive identification

**In-app synthetic recovery**

1. Switch solver to **MPM**, place at least one heap (active particles).
2. Tap **Teacher** to capture a synthetic observation from default rice (`φ≈34°`, default `E`).
3. Tap **Fit ID** — live params are reset to a wrong guess (`φ=28°`, softer `E`).
4. Watch HUD: loss `L`, gradient norm, and recovering `φ`, `E`.
5. Export via `AppModel.exportDiagnosticsSnapshot()` (includes `identification` block).

**Pass criteria (synthetic)**

- Loss decreases over ≥10 ID iterations when particles are active
- Recovered `φ` within ±4° of teacher under a stable pour
- Mass drift remains below Phase 1 threshold while fitting

**Physical (offline)**

Replace Teacher capture with Target from vision/surface observations once RGB-D cues exist; keep the same FD Adam loop.

---

## Phase 3 — Bayesian posterior & surface uncertainty

**In-app**

1. Complete Phase 2 Teacher → Fit ID so FD gradients accumulate.
2. Tap **Show σ** to enable mean / upper-band surfaces on the unlocked tier.
3. HUD reports `φ±σ`, `E±σ`, and surface `σ̄` / `σmax`.
4. Export JSON includes `posterior` and `surfaceUncertainty` blocks.

**Pass criteria**

- Posterior σ on `φ` contracts as ID iterations accumulate informative gradients
- Ensemble surface `σ̄` is larger under a diffuse prior / few observations than after many ID ticks
- Uncertainty meshes remain inside the ring fill radius

---

## Phase 4 — Adaptive multiresolution

**In-app**

1. Switch to **MPM**, place heaps so particles exist.
2. Tap **Adapt On** to enable particle split (fine / contact) and sleep-coarsen (bulk).
3. Tap **Show e** for the indicator heatmap (fine = warmer / taller cells).
4. Disturb with the scoop near the ring foot — fine particle count and split Δ+ should rise locally.
5. Export JSON `adaptivity` block for fine/base/coarse counts.

**Pass criteria**

- Fine cells concentrate near tool capsules and ring foot
- Coarse/sleep particle count increases in deep settled bulk
- Mass stays finite (splits are mass-conserving 1→2); no runaway particle growth beyond empty-slot budget

---

## Phase 5 — Physics-constrained neural residual

**In-app**

1. MPM mode with poured material present (DEM height field also updating).
2. Tap **Neural On** to train the residual MLP against the DEM height teacher (online Adam).
3. Tap **Show δh** for the green corrected surface overlay.
4. HUD: train loss `L`, mean `|δh|`, corrected mass drift `Δm`, repose violation count.
5. Export JSON `neuralResidual` block.

**Pass criteria**

- Online loss decreases over a pour/settle window
- Corrected surface mass drift stays small after projection
- Repose projection keeps neighbor slopes near `tan(φ)`
