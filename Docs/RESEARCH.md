# Differentiable Granular Digital Twin

## Research claim

> A wearable spatial computer can estimate constitutive parameters of granular material from interactive pour/contact observations and maintain a real-time multiresolution digital twin coupled to tracked hands and rigid ritual objects.

The 37-heaps mandala is the **demonstration case**, not the scientific claim. Relevance extends to robotic manipulation, soil mechanics, industrial pouring, and remote laboratories.

## Problem statement

How can a wearable spatial computer identify, simulate, and render real granular material interacting with tracked human hands and physical ritual objects in real time?

This couples:

- Computational mechanics (MPM / elastoplasticity)
- Inverse problems and system identification
- GPU architecture (Metal compute)
- Computer vision / spatial tracking (ARKit)
- Human–computer interaction (visionOS)

## Phase 1 scope (completed)

Dual-solver architecture:

1. **DEM + height field** — interactive baseline (`GrainGPUSimulator`)
2. **MLS/APIC-MPM + Drucker–Prager** — active-region continuum core (`MPMSimulator`)
3. **Conservation diagnostics** — mass / momentum / penetration probes
4. **Kinematic rigid coupling** — plate, open ring wall, phalanx/scoop SDFs
5. **Experiment protocol** — repose, ring-lift, scoop intrusion (see `Experiments/ExperimentProtocol.md`)

## Phase 2 scope (this repository)

Differentiability + online constitutive identification (no full Metal reverse-mode yet):

1. **Observation features** — mean pack height, radial spread, kinetic energy, repose proxy from MPM particles / DEM surface
2. **Surface–velocity loss** — weighted MSE between predicted features and a captured / synthetic target
3. **Finite-difference sensitivity** — central differences of loss w.r.t. `φ` and `E` via a shadow MPM rollout from a particle checkpoint
4. **Online fit** — Adam-style updates applied to the live MPM constitutive parameters while the ritual runs

Committed Phase 2 choice: **checkpointed FD gradients** on a shadow forward model. Checkpointed reverse-mode through Metal remains a later refinement once FD fit is stable.

## Phase 3 scope (this repository)

Bayesian posterior + pile-surface uncertainty:

1. **Parameter posterior** — diagonal / 2×2 Gaussian Laplace–Gauss–Newton posterior over `(φ, log E)` with weakly informative priors
2. **Online Fisher accumulation** — outer products of FD gradients from Phase 2 ID ticks
3. **Surface uncertainty field** — ensemble propagation of posterior samples through shadow MPM → coarse height mean / std
4. **Uncertainty bands** — RealityKit visualization of mean pack surface ± σ and HUD credible intervals

## Phase 4 scope (this repository)

Adaptive multiresolution error indicators:

1. **Local indicators** — per-cell scores from contact proximity (tool / ring foot), velocity / KE, and deformation (`‖F−I‖`, `‖C‖`)
2. **Refinement tiers** — classify cells as coarse / base / fine from combined indicator thresholds
3. **Particle adaptivity** — split high-error particles into empty slots; coarsen / sleep deep low-error pack (bridge toward DEM height-field bulk)
4. **Indicator visualization** — heatmap overlay + HUD counts of fine / base / coarse particles

Committed Phase 4 choice: **particle-level adaptivity** on the existing fixed MPM grid (no runtime grid realloc). Full remeshing / hierarchical grids remain a later refinement.

## Phase 5 scope (this repository)

Physics-constrained neural residual correction for settled regions:

1. **Tiny residual MLP** — pure-Swift network predicting per-cell height residuals `δh` from local physics features (`h`, radius, `φ`, `E`, contact)
2. **Physics projection** — non-negative heights, approximate mass conservation (`Σh` preserved), soft repose slope limit from current `φ`
3. **Settled-region gating** — residuals applied mainly where kinetic energy / adaptivity tier is coarse (bridge MPM → DEM bulk)
4. **Online training** — SGD/Adam against DEM height-field teacher (or synthetic target); HUD reports train loss + ‖δh‖

Committed Phase 5 choice: **hybrid residual** (physics forward + learned correction), not a full neural MPM replacement. Larger Core ML / Metal ML models remain optional later.

Deferred further: full lab campaign, full MCMC, hierarchical Eulerian grids, large pretrained surrogates.

## Central contributions (roadmap)

1. Metal-native MLS/APIC-MPM forward solver for a wearable spatial computer
2. Latency-aware coupling between tracked hands, rigid rings, and granular continua
3. Adaptive resolution guided by contact and perception (Phase 4)
4. Online identification of granular parameters from headset observations (Phase 2 FD; reverse-mode later)
5. Bayesian posterior + uncertainty bands on the pile surface (Phase 3)
6. Physics-constrained neural surrogates for settled regions (Phase 5)
7. Experimental validation with physical rice and mandala-ring procedures (later)

## Working title

**Differentiable Multiresolution Granular Digital Twins for Real-Time Hand Interaction in Spatial Computing**

## Related work (pointers)

- NeRF-driven granular parameter inversion from images
- CK-MPM / MLS-MPM compact kernels
- Differentiable MPM solvers for sensitivity and inverse analysis
- GPU async coupling of MPM materials and rigid bodies
- NeuralMPM and reduced-order granular surrogates
- Apple visionOS hand tracking and RealityKit LowLevelMesh / custom systems

## Code map

| Path | Role |
|------|------|
| `Mandala37Heaps/Models/GrainGPUSimulator.swift` | DEM + height-field baseline |
| `Mandala37Heaps/Shaders/GrainSimulation.metal` | DEM / hash / height-field kernels |
| `Mandala37Heaps/Research/MPM/` | Continuum particle/grid/constitutive + driver |
| `Mandala37Heaps/Shaders/MPMSimulation.metal` | P2G / grid / G2P / plasticity |
| `Mandala37Heaps/Research/Diagnostics/` | Conservation probes |
| `Mandala37Heaps/Research/Identification/` | Observation loss, FD sensitivity, online fit |
| `Mandala37Heaps/Research/Bayesian/` | Parameter posterior + surface uncertainty bands |
| `Mandala37Heaps/Research/Adaptivity/` | Error indicators + particle refine/coarsen |
| `Mandala37Heaps/Research/Neural/` | Physics-constrained residual MLP for settled pack |
| `Mandala37Heaps/Experiments/` | Physical / synthetic protocols |

## Validation stance

A beautiful demo is not evidence. Phase 1 requires conservation residuals, documented experiments, and parameter sweeps for repose angle. Phase 2 requires decreasing observation loss under FD updates and parameter recovery on synthetic teacher targets before trusting headset-driven identification. Phase 3 requires credible intervals that contract with informative observations and surface σ bands that widen under parameter ambiguity. Phase 4 requires fine particles to concentrate near tools/ring foot and coarse/sleep counts to rise in the settled bulk without mass blow-up. Phase 5 requires residual loss to decrease online while mass drift of the corrected surface stays within a stated band and slopes respect the repose constraint.
