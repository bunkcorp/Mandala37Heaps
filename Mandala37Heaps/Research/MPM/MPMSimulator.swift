import Foundation
import Metal
import RealityKit
import simd
import UIKit

/// MLS/APIC-MPM driver for one mandala tier active region.
@MainActor
final class MPMSimulator {
    static let maxParticles = 8_192
    static let pourCount = 1_200
    static let maxBillboards = 2_048
    static let maxCapsules = 8

    private struct MeshVertex {
        var position: SIMD3<Float> = .zero
        var normal: SIMD3<Float> = .zero
        var color: SIMD4<Float> = .zero
    }

    private struct HostDiagnostics {
        var activeCount: UInt32 = 0
        var sleepCount: UInt32 = 0
        var massSum: Float = 0
        var momX: Float = 0
        var momY: Float = 0
        var momZ: Float = 0
        var maxPenetrationU: UInt32 = 0
        var yieldViolations: UInt32 = 0
    }

    let tier: MandalaTier
    private(set) var constitutive: ConstitutiveParams
    private(set) var grid: MPMGridConfig
    let probe = ConservationProbe()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let clearPSO: MTLComputePipelineState
    private let p2gPSO: MTLComputePipelineState
    private let gridPSO: MTLComputePipelineState
    private let g2pPSO: MTLComputePipelineState
    private let emitPSO: MTLComputePipelineState
    private let billboardPSO: MTLComputePipelineState

    private let particleBuffer: MTLBuffer
    private let gridMassBuffer: MTLBuffer
    private let gridVxBuffer: MTLBuffer
    private let gridVyBuffer: MTLBuffer
    private let gridVzBuffer: MTLBuffer
    private let capsuleBuffer: MTLBuffer
    private let diagBuffer: MTLBuffer
    private let impulseXBuffer: MTLBuffer
    private let impulseYBuffer: MTLBuffer
    private let impulseZBuffer: MTLBuffer
    private let billboardCountBuffer: MTLBuffer

    private var uniforms: MPMUniforms
    private var nextParticleSlot: UInt32 = 0
    private var frameIndex: UInt64 = 0
    private var capsules: [MPMCapsuleSDF] = []

    private var hostEntity: Entity?
    private var particleEntity: ModelEntity?
    private var particleMesh: LowLevelMesh?

    init?(tier: MandalaTier, constitutive: ConstitutiveParams = .defaultRice) {
        self.tier = tier
        self.constitutive = constitutive
        self.grid = .forTier(tier)

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        self.device = device
        self.queue = queue

        do {
            func pso(_ name: String) throws -> MTLComputePipelineState {
                guard let fn = library.makeFunction(name: name) else {
                    throw NSError(domain: "MPM", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Missing Metal function \(name)"
                    ])
                }
                return try device.makeComputePipelineState(function: fn)
            }
            clearPSO = try pso("mpmClearGrid")
            p2gPSO = try pso("mpmP2G")
            gridPSO = try pso("mpmGridUpdate")
            g2pPSO = try pso("mpmG2P")
            emitPSO = try pso("mpmEmitPour")
            billboardPSO = try pso("mpmBuildBillboards")
        } catch {
            print("[MPM] pipeline error: \(error)")
            return nil
        }

        let nodeCount = grid.nodeCount
        let pLen = MPMParticle.stride * Self.maxParticles
        let nLen = MemoryLayout<Float>.stride * nodeCount
        let capLen = MemoryLayout<SIMD4<Float>>.stride * 2 * Self.maxCapsules
        let diagLen = max(MemoryLayout<HostDiagnostics>.stride, 64)
        guard let particleBuffer = device.makeBuffer(length: pLen, options: .storageModeShared),
              let gridMassBuffer = device.makeBuffer(length: nLen, options: .storageModeShared),
              let gridVxBuffer = device.makeBuffer(length: nLen, options: .storageModeShared),
              let gridVyBuffer = device.makeBuffer(length: nLen, options: .storageModeShared),
              let gridVzBuffer = device.makeBuffer(length: nLen, options: .storageModeShared),
              let capsuleBuffer = device.makeBuffer(length: capLen, options: .storageModeShared),
              let diagBuffer = device.makeBuffer(length: diagLen, options: .storageModeShared),
              let impulseXBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModeShared),
              let impulseYBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModeShared),
              let impulseZBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModeShared),
              let billboardCountBuffer = device.makeBuffer(
                length: MemoryLayout<UInt32>.stride,
                options: .storageModeShared
              )
        else {
            return nil
        }
        self.particleBuffer = particleBuffer
        self.gridMassBuffer = gridMassBuffer
        self.gridVxBuffer = gridVxBuffer
        self.gridVyBuffer = gridVyBuffer
        self.gridVzBuffer = gridVzBuffer
        self.capsuleBuffer = capsuleBuffer
        self.diagBuffer = diagBuffer
        self.impulseXBuffer = impulseXBuffer
        self.impulseYBuffer = impulseYBuffer
        self.impulseZBuffer = impulseZBuffer
        self.billboardCountBuffer = billboardCountBuffer

        memset(particleBuffer.contents(), 0, pLen)

        uniforms = MPMUniforms(
            dt: 1 / 90,
            dx: grid.dx,
            invDx: 1 / grid.dx,
            gravityY: -9.81,
            originX: grid.origin.x,
            originY: grid.origin.y,
            originZ: grid.origin.z,
            fillRadius: tier.fillRadius,
            plateY: 0,
            maxHeight: tier.ringHeight,
            nx: UInt32(grid.nx),
            ny: UInt32(grid.ny),
            nz: UInt32(grid.nz),
            particleCount: UInt32(Self.maxParticles),
            density: constitutive.density,
            youngs: constitutive.youngsModulus,
            poisson: constitutive.poisson,
            alphaFriction: constitutive.alphaFriction,
            cohesion: constitutive.cohesion,
            capPressure: constitutive.capPressure,
            sleepDepth: 0.014,
            capsuleCount: 0
        )
        writeInactiveCapsules()
    }

    func attach(to tierEntity: Entity) {
        hostEntity?.removeFromParent()
        let host = Entity()
        host.name = "MPMGrainHost"
        let surface = tierEntity.findEntity(named: "TierSurface") ?? tierEntity
        surface.addChild(host)
        hostEntity = host
        host.isEnabled = false

        do {
            try buildMeshIfNeeded()
            if let particleEntity { host.addChild(particleEntity) }
        } catch {
            print("[MPM] mesh attach failed: \(error)")
        }
    }

    func setEnabled(_ enabled: Bool) {
        hostEntity?.isEnabled = enabled
    }

    func setConstitutive(_ params: ConstitutiveParams) {
        let p = params.sanitized()
        constitutive = p
        uniforms.density = p.density
        uniforms.youngs = p.youngsModulus
        uniforms.poisson = p.poisson
        uniforms.alphaFriction = p.alphaFriction
        uniforms.cohesion = p.cohesion
        uniforms.capPressure = p.capPressure
    }

    /// Update kinematic SDF capsules (tier-local phalanges / scoop).
    func setContactCapsules(_ capsules: [MPMCapsuleSDF]) {
        self.capsules = Array(capsules.prefix(Self.maxCapsules))
        uniforms.capsuleCount = UInt32(self.capsules.count)
        let ptr = capsuleBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxCapsules * 2)
        for i in 0..<Self.maxCapsules {
            if i < self.capsules.count {
                let packed = self.capsules[i].packed
                ptr[i * 2] = packed.0
                ptr[i * 2 + 1] = packed.1
            } else {
                let inactive = MPMCapsuleSDF.inactive.packed
                ptr[i * 2] = inactive.0
                ptr[i * 2 + 1] = inactive.1
            }
        }
    }

    func pour(at localXZ: SIMD2<Float>, ritualProgress: Float) {
        let surfaceY = max(0.01, ritualProgress * uniforms.maxHeight * 0.35)
        var centerCount = SIMD4<Float>(localXZ.x, surfaceY + 0.03, localXZ.y, Float(Self.pourCount))
        var start = nextParticleSlot
        nextParticleSlot = (nextParticleSlot + UInt32(Self.pourCount)) % UInt32(Self.maxParticles)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var u = uniforms
        encoder.setComputePipelineState(emitPSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<MPMUniforms>.stride, index: 1)
        encoder.setBytes(&centerCount, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        encoder.setBytes(&start, length: MemoryLayout<UInt32>.stride, index: 3)
        dispatch(encoder, threads: Self.pourCount, pso: emitPSO)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        GrainAudio.shared.playPour(intensity: 0.65 + ritualProgress * 0.35)
    }

    func step(dt: Float) {
        stepInternal(dt: dt, updateMesh: true)
    }

    /// Physics-only step for shadow FD rollouts (no LowLevelMesh traffic).
    func stepPhysicsOnly(dt: Float) {
        stepInternal(dt: dt, updateMesh: false)
    }

    /// Copy particle SoA from another simulator (same capacity).
    func copyParticles(from other: MPMSimulator) {
        let bytes = MPMParticle.stride * Self.maxParticles
        memcpy(particleBuffer.contents(), other.particleBuffer.contents(), bytes)
        nextParticleSlot = other.nextParticleSlot
    }

    func captureParticleCheckpoint() -> Data {
        Data(
            bytes: particleBuffer.contents(),
            count: MPMParticle.stride * Self.maxParticles
        )
    }

    func restoreParticleCheckpoint(_ data: Data) {
        let expected = MPMParticle.stride * Self.maxParticles
        guard data.count == expected else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(particleBuffer.contents(), base, expected)
        }
    }

    /// Iterate host-visible particles (shared Metal buffer).
    func forEachParticle(_ body: (_ index: Int, _ particle: MPMParticle) -> Void) {
        let ptr = particleBuffer.contents().bindMemory(to: MPMParticle.self, capacity: Self.maxParticles)
        for i in 0..<Self.maxParticles {
            body(i, ptr[i])
        }
    }

    /// Split fine-region particles into empty slots (mass-conserving 1→2).
    @discardableResult
    func splitParticles(indices: [Int], maxCount: Int) -> Int {
        guard maxCount > 0, !indices.isEmpty else { return 0 }
        let ptr = particleBuffer.contents().bindMemory(to: MPMParticle.self, capacity: Self.maxParticles)
        var empty: [Int] = []
        empty.reserveCapacity(64)
        for i in 0..<Self.maxParticles where ptr[i].state == 0 {
            empty.append(i)
            if empty.count >= maxCount { break }
        }
        var splits = 0
        var emptyCursor = 0
        for parentIndex in indices {
            guard splits < maxCount, emptyCursor < empty.count else { break }
            guard parentIndex >= 0, parentIndex < Self.maxParticles else { continue }
            var parent = ptr[parentIndex]
            guard parent.state == 1, parent.mass.isFinite, parent.mass > 1e-8 else { continue }

            let childIndex = empty[emptyCursor]
            emptyCursor += 1

            let halfMass = parent.mass * 0.5
            let halfVol = parent.volume0 * 0.5
            parent.mass = halfMass
            parent.volume0 = halfVol

            var child = parent
            // Jitter so children don't occupy the same quadrature point.
            let jitter = SIMD3<Float>(
                Float.random(in: -0.4...0.4) * grid.dx,
                Float.random(in: 0...0.2) * grid.dx,
                Float.random(in: -0.4...0.4) * grid.dx
            )
            child.position = grid.clampParticle(to: parent.position + jitter)
            child.mass = halfMass
            child.volume0 = halfVol
            child.state = 1

            ptr[parentIndex] = parent
            ptr[childIndex] = child
            splits += 1
        }
        return splits
    }

    /// Put low-error bulk particles to sleep (coarsen toward height-field bulk).
    @discardableResult
    func coarsenParticles(indices: [Int], maxCount: Int) -> Int {
        guard maxCount > 0, !indices.isEmpty else { return 0 }
        let ptr = particleBuffer.contents().bindMemory(to: MPMParticle.self, capacity: Self.maxParticles)
        var count = 0
        for index in indices {
            guard count < maxCount else { break }
            guard index >= 0, index < Self.maxParticles else { continue }
            var p = ptr[index]
            guard p.state == 1 else { continue }
            p.state = 2
            p.velocity = .zero
            // Zero affine for sleeping bulk.
            p.c0 = 0; p.c1 = 0; p.c2 = 0
            p.c3 = 0; p.c4 = 0; p.c5 = 0
            p.c6 = 0; p.c7 = 0; p.c8 = 0
            ptr[index] = p
            count += 1
        }
        return count
    }

    /// Max-height histogram on an XZ grid (for surface uncertainty ensembles).
    @discardableResult
    func binSurfaceHeights(
        resolution: Int,
        fillRadius: Float,
        into heights: inout [Float]
    ) -> Bool {
        let n = resolution * resolution
        guard heights.count == n, resolution > 1 else { return false }
        for i in 0..<n { heights[i] = 0 }

        let ptr = particleBuffer.contents().bindMemory(to: MPMParticle.self, capacity: Self.maxParticles)
        var any = false
        for i in 0..<Self.maxParticles {
            let p = ptr[i]
            guard p.state != 0 else { continue }
            let x = p.position
            let r = hypot(x.x, x.z)
            guard r <= fillRadius else { continue }
            let u = (x.x / fillRadius + 1) * 0.5
            let v = (x.z / fillRadius + 1) * 0.5
            let ix = min(max(Int(u * Float(resolution)), 0), resolution - 1)
            let jz = min(max(Int(v * Float(resolution)), 0), resolution - 1)
            let idx = jz * resolution + ix
            heights[idx] = max(heights[idx], x.y)
            any = true
        }
        return any
    }

    /// Reduced observation features for inverse identification.
    func sampleObservation() -> GranularObservation {
        let ptr = particleBuffer.contents().bindMemory(to: MPMParticle.self, capacity: Self.maxParticles)
        var count = 0
        var massSum: Float = 0
        var heightSum: Float = 0
        var radiusSum: Float = 0
        var keSum: Float = 0
        var maxH: Float = 0
        var maxR: Float = 0

        for i in 0..<Self.maxParticles {
            let p = ptr[i]
            guard p.state != 0 else { continue }
            let m = p.mass
            let x = p.position
            let v = p.velocity
            guard m.isFinite, m > 0, x.x.isFinite, x.y.isFinite, x.z.isFinite,
                  v.x.isFinite, v.y.isFinite, v.z.isFinite else { continue }
            let r = hypot(x.x, x.z)
            count += 1
            massSum += m
            heightSum += m * x.y
            radiusSum += m * r
            keSum += 0.5 * m * length_squared(v)
            maxH = max(maxH, x.y)
            maxR = max(maxR, r)
        }

        guard count > 0, massSum > 1e-8 else {
            return .empty
        }

        let meanH = heightSum / massSum
        let meanR = radiusSum / massSum
        // Cone repose proxy: atan(meanH / max(meanR, ε))
        let repose = atan2(meanH, max(meanR, 1e-4)) * 180 / Float.pi
        return GranularObservation(
            meanHeight: meanH,
            peakHeight: maxH,
            meanRadius: meanR,
            peakRadius: maxR,
            kineticEnergy: keSum,
            reposeDegrees: repose,
            particleCount: count,
            totalMass: massSum
        )
    }

    var latestDiagnostics: ConservationSnapshot { probe.latest }

    private func stepInternal(dt: Float, updateMesh: Bool) {
        let frameDt = min(max(dt, 1 / 240), 1 / 45)
        let substeps = 2
        uniforms.dt = frameDt / Float(substeps)
        frameIndex &+= 1

        let uLen = MemoryLayout<MPMUniforms>.stride
        let nodes = grid.nodeCount

        for sub in 0..<substeps {
            clearDiagnosticsHost()
            clearImpulsesHost()

            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            let isLast = sub == substeps - 1
            let meshVerts: MTLBuffer?
            let meshIndices: MTLBuffer?
            if updateMesh, isLast, let particleMesh {
                meshVerts = particleMesh.replace(bufferIndex: 0, using: commandBuffer)
                meshIndices = particleMesh.replaceIndices(using: commandBuffer)
                billboardCountBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            } else {
                meshVerts = nil
                meshIndices = nil
            }

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            var u = uniforms

            encoder.setComputePipelineState(clearPSO)
            encoder.setBuffer(gridMassBuffer, offset: 0, index: 0)
            encoder.setBuffer(gridVxBuffer, offset: 0, index: 1)
            encoder.setBuffer(gridVyBuffer, offset: 0, index: 2)
            encoder.setBuffer(gridVzBuffer, offset: 0, index: 3)
            encoder.setBytes(&u, length: uLen, index: 4)
            dispatch(encoder, threads: nodes, pso: clearPSO)

            encoder.setComputePipelineState(p2gPSO)
            encoder.setBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setBuffer(gridMassBuffer, offset: 0, index: 1)
            encoder.setBuffer(gridVxBuffer, offset: 0, index: 2)
            encoder.setBuffer(gridVyBuffer, offset: 0, index: 3)
            encoder.setBuffer(gridVzBuffer, offset: 0, index: 4)
            encoder.setBytes(&u, length: uLen, index: 5)
            dispatch(encoder, threads: Self.maxParticles, pso: p2gPSO)

            encoder.setComputePipelineState(gridPSO)
            encoder.setBuffer(gridMassBuffer, offset: 0, index: 0)
            encoder.setBuffer(gridVxBuffer, offset: 0, index: 1)
            encoder.setBuffer(gridVyBuffer, offset: 0, index: 2)
            encoder.setBuffer(gridVzBuffer, offset: 0, index: 3)
            encoder.setBytes(&u, length: uLen, index: 4)
            encoder.setBuffer(capsuleBuffer, offset: 0, index: 5)
            encoder.setBuffer(impulseXBuffer, offset: 0, index: 6)
            encoder.setBuffer(impulseYBuffer, offset: 0, index: 7)
            encoder.setBuffer(impulseZBuffer, offset: 0, index: 8)
            encoder.setBuffer(diagBuffer, offset: 0, index: 9)
            dispatch(encoder, threads: nodes, pso: gridPSO)

            encoder.setComputePipelineState(g2pPSO)
            encoder.setBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setBuffer(gridMassBuffer, offset: 0, index: 1)
            encoder.setBuffer(gridVxBuffer, offset: 0, index: 2)
            encoder.setBuffer(gridVyBuffer, offset: 0, index: 3)
            encoder.setBuffer(gridVzBuffer, offset: 0, index: 4)
            encoder.setBytes(&u, length: uLen, index: 5)
            encoder.setBuffer(diagBuffer, offset: 0, index: 6)
            dispatch(encoder, threads: Self.maxParticles, pso: g2pPSO)

            if let meshVerts, let meshIndices {
                var maxBillboards = UInt32(Self.maxBillboards)
                encoder.setComputePipelineState(billboardPSO)
                encoder.setBuffer(particleBuffer, offset: 0, index: 0)
                encoder.setBuffer(meshVerts, offset: 0, index: 1)
                encoder.setBuffer(meshIndices, offset: 0, index: 2)
                encoder.setBuffer(billboardCountBuffer, offset: 0, index: 3)
                encoder.setBytes(&u, length: uLen, index: 4)
                encoder.setBytes(&maxBillboards, length: MemoryLayout<UInt32>.stride, index: 5)
                dispatch(encoder, threads: Self.maxParticles, pso: billboardPSO)
            }

            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        if updateMesh {
            let written = min(
                Int(billboardCountBuffer.contents().load(as: UInt32.self)),
                Self.maxBillboards
            )
            updateMeshParts(billboardCount: written)
        }
        readDiagnostics(dt: frameDt)
    }

    // MARK: - Private

    private func dispatch(_ encoder: MTLComputeCommandEncoder, threads: Int, pso: MTLComputePipelineState) {
        let w = pso.threadExecutionWidth
        let tg = MTLSize(width: w, height: 1, depth: 1)
        let groups = MTLSize(width: (threads + w - 1) / w, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
    }

    private func clearDiagnosticsHost() {
        memset(diagBuffer.contents(), 0, MemoryLayout<HostDiagnostics>.stride)
    }

    private func clearImpulsesHost() {
        impulseXBuffer.contents().storeBytes(of: Float(0), as: Float.self)
        impulseYBuffer.contents().storeBytes(of: Float(0), as: Float.self)
        impulseZBuffer.contents().storeBytes(of: Float(0), as: Float.self)
    }

    private func writeInactiveCapsules() {
        setContactCapsules([])
    }

    private func readDiagnostics(dt: Float) {
        // Atomic layout in Metal may not match HostDiagnostics exactly for floats.
        // Read raw: uint,uint,float,float,float,float,uint,uint
        let base = diagBuffer.contents()
        let active = base.load(as: UInt32.self)
        let sleep = base.load(fromByteOffset: 4, as: UInt32.self)
        let mass = base.load(fromByteOffset: 8, as: Float.self)
        let mx = base.load(fromByteOffset: 12, as: Float.self)
        let my = base.load(fromByteOffset: 16, as: Float.self)
        let mz = base.load(fromByteOffset: 20, as: Float.self)
        let penU = base.load(fromByteOffset: 24, as: UInt32.self)
        let yield = base.load(fromByteOffset: 28, as: UInt32.self)

        let ix = impulseXBuffer.contents().load(as: Float.self)
        let iy = impulseYBuffer.contents().load(as: Float.self)
        let iz = impulseZBuffer.contents().load(as: Float.self)

        probe.ingest(
            frame: frameIndex,
            active: active,
            sleeping: sleep,
            mass: mass,
            momentum: SIMD3(mx, my, mz),
            maxPenetration: Float(penU) * 1e-6,
            yieldViolations: yield,
            ringImpulse: SIMD3(ix, iy, iz),
            dt: dt,
            gravityY: uniforms.gravityY,
            gridNodes: grid.nodeCount,
            constitutive: constitutive
        )
    }

    private func updateMeshParts(billboardCount: Int) {
        let fillR = uniforms.fillRadius
        particleMesh?.parts[0] = LowLevelMesh.Part(
            indexCount: billboardCount * 6,
            topology: .triangle,
            materialIndex: 0,
            bounds: BoundingBox(
                min: SIMD3(-fillR, 0, -fillR),
                max: SIMD3(fillR, uniforms.maxHeight, fillR)
            )
        )
    }

    private func buildMeshIfNeeded() throws {
        guard particleMesh == nil else { return }
        let capacity = Self.maxBillboards
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = capacity * 4
        desc.indexCapacity = capacity * 6
        desc.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout.offset(of: \MeshVertex.position)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout.offset(of: \MeshVertex.normal)!),
            .init(semantic: .color, format: .float4, offset: MemoryLayout.offset(of: \MeshVertex.color)!)
        ]
        desc.vertexLayouts = [
            .init(bufferIndex: 0, bufferStride: MemoryLayout<MeshVertex>.stride)
        ]
        desc.indexType = .uint32
        let mesh = try LowLevelMesh(descriptor: desc)
        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: 0,
                topology: .triangle,
                materialIndex: 0,
                bounds: BoundingBox(
                    min: SIMD3(-uniforms.fillRadius, 0, -uniforms.fillRadius),
                    max: SIMD3(uniforms.fillRadius, uniforms.maxHeight, uniforms.fillRadius)
                )
            )
        ])
        particleMesh = mesh
        let resource = try MeshResource(from: mesh)
        var mat = SimpleMaterial()
        mat.color = .init(tint: UIColor(red: 0.93, green: 0.86, blue: 0.62, alpha: 1))
        mat.roughness = .float(0.88)
        let model = ModelEntity(mesh: resource, materials: [mat])
        model.name = "MPMParticles"
        particleEntity = model
    }
}

enum SolverMode: String, CaseIterable, Identifiable, Sendable {
    case dem
    case mpmActive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dem: return "DEM"
        case .mpmActive: return "MPM"
        }
    }
}
