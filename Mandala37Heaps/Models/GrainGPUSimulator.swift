import Foundation
import Metal
import RealityKit
import simd
import UIKit

/// GPU grain pour: DEM + height field, with buried sleep and GPU mesh updates.
@MainActor
final class GrainGPUSimulator {
    static let maxParticles = 24_576
    static let gridResolution = 64
    static let pourCount = 2_800
    static let maxBillboards = 4_096

    private struct GrainParticle {
        var position: SIMD3<Float> = .zero
        var velocity: SIMD3<Float> = .zero
        var radius: Float = 0.0032
        var mass: Float = 1
        var state: UInt32 = 0
        var pad: UInt32 = 0
    }

    /// Must match `GrainUniforms` in GrainSimulation.metal field-for-field.
    private struct GrainUniforms {
        var dt: Float
        var gravityY: Float
        var fillRadius: Float
        var maxHeight: Float
        var cellSize: Float
        var reposeTan: Float
        var settleSpeed: Float
        var depositScale: Float
        var gridRes: UInt32
        var particleCount: UInt32
        var hashCellSize: Float
        var hashResXZ: UInt32
        var hashResY: UInt32
        var demStiffness: Float
        var demDamping: Float
        var demFriction: Float
        var wakeImpulse: Float
        var sleepDepth: Float
    }

    private struct PourParams {
        var center: SIMD3<Float>
        var radius: Float
        var startSlot: UInt32
        var count: UInt32
        var particleCount: UInt32
        var pad0: UInt32 = 0
    }

    private struct MeshVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var color: SIMD4<Float>
    }

    let tier: MandalaTier
    private(set) var fillProgress: Float = 0.03
    private var lastPublishedProgress: Float = -1
    private var cachedSurfaceY: Float = 0.01
    private var frameIndex: UInt64 = 0

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private let integratePSO: MTLComputePipelineState
    private let sleepPSO: MTLComputePipelineState
    private let clearHashPSO: MTLComputePipelineState
    private let insertHashPSO: MTLComputePipelineState
    private let demPSO: MTLComputePipelineState
    private let wakePSO: MTLComputePipelineState
    private let depositPSO: MTLComputePipelineState
    private let relaxPSO: MTLComputePipelineState
    private let pulsePSO: MTLComputePipelineState
    private let raiseFloorPSO: MTLComputePipelineState
    private let compressHeightPSO: MTLComputePipelineState
    private let heightSumPSO: MTLComputePipelineState
    private let compressWakePSO: MTLComputePipelineState
    private let disturbToolPSO: MTLComputePipelineState
    private let emitPourPSO: MTLComputePipelineState
    private let buildHeightMeshPSO: MTLComputePipelineState
    private let buildParticleMeshPSO: MTLComputePipelineState

    private let particleBuffer: MTLBuffer
    private let heightBuffer: MTLBuffer
    private let cellHeadBuffer: MTLBuffer
    private let nextIndexBuffer: MTLBuffer
    private let heightSumBuffer: MTLBuffer
    private let billboardCountBuffer: MTLBuffer
    private let hashCellCount: Int

    private var uniforms: GrainUniforms
    private var nextParticleSlot: UInt32 = 0
    /// Frames remaining where settle audio is allowed after a pour / ring press.
    private var settleAudioFramesRemaining: Int = 0

    private var hostEntity: Entity?
    private var surfaceEntity: ModelEntity?
    private var particleEntity: ModelEntity?
    private var surfaceMesh: LowLevelMesh?
    private var particleMesh: LowLevelMesh?

    init?(tier: MandalaTier) {
        self.tier = tier
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
                    throw NSError(domain: "GrainGPU", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Missing Metal function \(name)"
                    ])
                }
                return try device.makeComputePipelineState(function: fn)
            }
            integratePSO = try pso("integrateGrains")
            sleepPSO = try pso("sleepBuriedGrains")
            clearHashPSO = try pso("clearHashHeads")
            insertHashPSO = try pso("insertHash")
            demPSO = try pso("demContacts")
            wakePSO = try pso("wakeAvalancheCandidates")
            depositPSO = try pso("depositGrains")
            relaxPSO = try pso("relaxHeightField")
            pulsePSO = try pso("addPulse")
            raiseFloorPSO = try pso("raiseHeightFloor")
            compressHeightPSO = try pso("compressHeightField")
            heightSumPSO = try pso("accumulateHeightSum")
            compressWakePSO = try pso("compressWakeBand")
            disturbToolPSO = try pso("disturbWithTool")
            emitPourPSO = try pso("emitPourBurst")
            buildHeightMeshPSO = try pso("buildHeightFieldMesh")
            buildParticleMeshPSO = try pso("buildParticleBillboards")
        } catch {
            print("[GrainGPU] pipeline error: \(error)")
            return nil
        }

        let fillRadius = tier.fillRadius
        let maxHeight = tier.ringHeight
        let hashCell: Float = 0.010
        let hashXZ = UInt32(max(16, Int(ceil((fillRadius * 2) / hashCell))))
        let hashY = UInt32(max(4, Int(ceil(maxHeight / hashCell)) + 1))
        hashCellCount = Int(hashY * hashXZ * hashXZ)

        uniforms = GrainUniforms(
            dt: 1 / 90,
            gravityY: -9.81,
            fillRadius: fillRadius,
            maxHeight: maxHeight,
            cellSize: (fillRadius * 2) / Float(Self.gridResolution),
            reposeTan: tan(34 * Float.pi / 180),
            settleSpeed: 0.055,
            depositScale: 1.0,
            gridRes: UInt32(Self.gridResolution),
            particleCount: UInt32(Self.maxParticles),
            hashCellSize: hashCell,
            hashResXZ: hashXZ,
            hashResY: hashY,
            demStiffness: 220,
            demDamping: 1.8,
            demFriction: 0.55,
            wakeImpulse: 0.12,
            sleepDepth: 0.012
        )
        cachedSurfaceY = maxHeight * 0.03

        let pLen = MemoryLayout<GrainParticle>.stride * Self.maxParticles
        let hLen = MemoryLayout<UInt32>.stride * Self.gridResolution * Self.gridResolution
        let headLen = MemoryLayout<UInt32>.stride * hashCellCount
        let nextLen = MemoryLayout<UInt32>.stride * Self.maxParticles
        guard let particleBuffer = device.makeBuffer(length: pLen, options: .storageModeShared),
              let heightBuffer = device.makeBuffer(length: hLen, options: .storageModeShared),
              let cellHeadBuffer = device.makeBuffer(length: headLen, options: .storageModeShared),
              let nextIndexBuffer = device.makeBuffer(length: nextLen, options: .storageModeShared),
              let heightSumBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let billboardCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
        else {
            return nil
        }
        self.particleBuffer = particleBuffer
        self.heightBuffer = heightBuffer
        self.cellHeadBuffer = cellHeadBuffer
        self.nextIndexBuffer = nextIndexBuffer
        self.heightSumBuffer = heightSumBuffer
        self.billboardCountBuffer = billboardCountBuffer

        // Thin base height field.
        let base = UInt32(maxHeight * 0.03 * 1e6)
        let heightPtr = heightBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: Self.gridResolution * Self.gridResolution
        )
        for i in 0..<(Self.gridResolution * Self.gridResolution) {
            heightPtr[i] = base
        }
        memset(particleBuffer.contents(), 0, pLen)
    }

    func attach(to tierEntity: Entity) {
        hostEntity?.removeFromParent()
        let host = Entity()
        host.name = "GPUGrainHost"
        let surface = tierEntity.findEntity(named: "TierSurface") ?? tierEntity
        surface.addChild(host)
        hostEntity = host

        if let decorative = tierEntity.findEntity(named: "SurfaceGrains") {
            decorative.isEnabled = false
        }

        do {
            try buildMeshesIfNeeded()
            // Height-field mesh reads as a flat cream/pink square on the plate — keep
            // the sim, hide the surface. Particle billboards still show the pour.
            if let surfaceEntity {
                surfaceEntity.isEnabled = false
                host.addChild(surfaceEntity)
            }
            if let particleEntity { host.addChild(particleEntity) }
        } catch {
            print("[GrainGPU] mesh attach failed: \(error)")
        }

        publishFillProgressIfNeeded(force: true)
    }

    /// Pour a burst of GPU grains and pulse the height field under the offering.
    func pour(at localXZ: SIMD2<Float>, ritualProgress: Float) {
        let surfaceY = cachedSurfaceY
        var params = PourParams(
            center: SIMD3(localXZ.x, surfaceY, localXZ.y),
            radius: 0.048,
            startSlot: nextParticleSlot,
            count: UInt32(Self.pourCount),
            particleCount: UInt32(Self.maxParticles)
        )
        nextParticleSlot = (nextParticleSlot + UInt32(Self.pourCount)) % UInt32(Self.maxParticles)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(emitPourPSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<PourParams>.stride, index: 1)
        dispatch(encoder, threads: Self.pourCount, pso: emitPourPSO)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let target = max(0.05, min(1, ritualProgress)) * uniforms.maxHeight
        let add = max(0, target - surfaceY) * 0.55 + uniforms.maxHeight * 0.012
        dispatchPulse(center: localXZ, radius: 0.09, heightAdd: add)
        refreshHeightStats()
        publishFillProgressIfNeeded(force: true)
        settleAudioFramesRemaining = 90 // ~1.5s of settle ticks at 60fps
        GrainAudio.shared.playPour(intensity: 0.7 + ritualProgress * 0.4)
    }

    func step(dt: Float) {
        uniforms.dt = min(max(dt, 1 / 240), 1 / 30)
        frameIndex &+= 1

        guard let surfaceMesh,
              let particleMesh,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        // Acquire RealityKit mesh buffers for this command buffer (GPU path).
        let heightVerts = surfaceMesh.replace(bufferIndex: 0, using: commandBuffer)
        let particleVerts = particleMesh.replace(bufferIndex: 0, using: commandBuffer)
        let particleIndices = particleMesh.replaceIndices(using: commandBuffer)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var u = uniforms
        let uLen = MemoryLayout<GrainUniforms>.stride

        // Simulate
        encoder.setComputePipelineState(integratePSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightBuffer, offset: 0, index: 1)
        encoder.setBytes(&u, length: uLen, index: 2)
        dispatch(encoder, threads: Self.maxParticles, pso: integratePSO)

        encoder.setComputePipelineState(sleepPSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightBuffer, offset: 0, index: 1)
        encoder.setBytes(&u, length: uLen, index: 2)
        dispatch(encoder, threads: Self.maxParticles, pso: sleepPSO)

        encoder.setComputePipelineState(clearHashPSO)
        encoder.setBuffer(cellHeadBuffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: uLen, index: 1)
        dispatch(encoder, threads: hashCellCount, pso: clearHashPSO)

        encoder.setComputePipelineState(insertHashPSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(cellHeadBuffer, offset: 0, index: 1)
        encoder.setBuffer(nextIndexBuffer, offset: 0, index: 2)
        encoder.setBytes(&u, length: uLen, index: 3)
        dispatch(encoder, threads: Self.maxParticles, pso: insertHashPSO)

        encoder.setComputePipelineState(demPSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(cellHeadBuffer, offset: 0, index: 1)
        encoder.setBuffer(nextIndexBuffer, offset: 0, index: 2)
        encoder.setBytes(&u, length: uLen, index: 3)
        dispatch(encoder, threads: Self.maxParticles, pso: demPSO)

        encoder.setComputePipelineState(wakePSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightBuffer, offset: 0, index: 1)
        encoder.setBuffer(cellHeadBuffer, offset: 0, index: 2)
        encoder.setBuffer(nextIndexBuffer, offset: 0, index: 3)
        encoder.setBytes(&u, length: uLen, index: 4)
        dispatch(encoder, threads: Self.maxParticles, pso: wakePSO)

        encoder.setComputePipelineState(depositPSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightBuffer, offset: 0, index: 1)
        encoder.setBytes(&u, length: uLen, index: 2)
        dispatch(encoder, threads: Self.maxParticles, pso: depositPSO)

        encoder.setComputePipelineState(relaxPSO)
        encoder.setBuffer(heightBuffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: uLen, index: 1)
        dispatch(encoder, threads: Self.gridResolution * Self.gridResolution, pso: relaxPSO)

        // Cheap fill stats (single atomic sum → one CPU word).
        heightSumBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        encoder.setComputePipelineState(heightSumPSO)
        encoder.setBuffer(heightBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightSumBuffer, offset: 0, index: 1)
        encoder.setBytes(&u, length: uLen, index: 2)
        dispatch(encoder, threads: Self.gridResolution * Self.gridResolution, pso: heightSumPSO)

        // GPU mesh updates
        encoder.setComputePipelineState(buildHeightMeshPSO)
        encoder.setBuffer(heightBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightVerts, offset: 0, index: 1)
        encoder.setBytes(&u, length: uLen, index: 2)
        dispatch(encoder, threads: Self.gridResolution * Self.gridResolution, pso: buildHeightMeshPSO)

        billboardCountBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        var maxBillboards = UInt32(Self.maxBillboards)
        encoder.setComputePipelineState(buildParticleMeshPSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(particleVerts, offset: 0, index: 1)
        encoder.setBuffer(particleIndices, offset: 0, index: 2)
        encoder.setBuffer(billboardCountBuffer, offset: 0, index: 3)
        encoder.setBytes(&u, length: uLen, index: 4)
        encoder.setBytes(&maxBillboards, length: MemoryLayout<UInt32>.stride, index: 5)
        dispatch(encoder, threads: Self.maxParticles, pso: buildParticleMeshPSO)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Only tiny CPU reads: average height + billboard count.
        let sum = heightSumBuffer.contents().load(as: UInt32.self)
        let cellCount = UInt32(Self.gridResolution * Self.gridResolution)
        cachedSurfaceY = Float(sum / max(cellCount, 1)) * 1e-6
        fillProgress = max(0.03, min(1, cachedSurfaceY / max(uniforms.maxHeight, 1e-4)))

        let written = min(
            Int(billboardCountBuffer.contents().load(as: UInt32.self)),
            Self.maxBillboards
        )
        updateMeshParts(billboardCount: written)

        // Publish bulk/slots at a throttled rate.
        if frameIndex % 3 == 0 {
            publishFillProgressIfNeeded(force: false)
        }

        // Soft settle ticks only for a short window after pour / ring press —
        // not for the entire life of a filled tier (that hissed forever after completion).
        if settleAudioFramesRemaining > 0 {
            settleAudioFramesRemaining -= 1
            if written > 400, frameIndex % 18 == 0 {
                let fade = Float(settleAudioFramesRemaining) / 90
                GrainAudio.shared.playSettle(
                    intensity: min(1, Float(written) / 3500) * max(0.2, fade)
                )
            }
        }
    }

    /// Wake / push grains near a ritual scoop or fingertip (tier-local sphere).
    func disturbWithTool(at localPosition: SIMD3<Float>, radius: Float = 0.045) {
        // Only affect the deck neighborhood.
        guard localPosition.y > -0.05, localPosition.y < uniforms.maxHeight + 0.12 else { return }
        let radial = hypot(localPosition.x, localPosition.z)
        guard radial < uniforms.fillRadius + 0.04 else { return }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var u = uniforms
        var tool = SIMD4<Float>(localPosition.x, localPosition.y, localPosition.z, radius)
        encoder.setComputePipelineState(disturbToolPSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightBuffer, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<GrainUniforms>.stride, index: 2)
        encoder.setBytes(&tool, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        dispatch(encoder, threads: Self.maxParticles, pso: disturbToolPSO)
        encoder.endEncoding()
        commandBuffer.commit()
        // No wait — next step() will integrate the kick.
    }

    func compressUnderRing() {
        settleAudioFramesRemaining = 120
        GrainAudio.shared.playRingPress()

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        var u = uniforms
        let uLen = MemoryLayout<GrainUniforms>.stride
        let cells = Self.gridResolution * Self.gridResolution

        encoder.setComputePipelineState(compressHeightPSO)
        encoder.setBuffer(heightBuffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: uLen, index: 1)
        dispatch(encoder, threads: cells, pso: compressHeightPSO)

        // Primary hard press near the ring foot.
        let outer = uniforms.fillRadius * 0.95
        let inner = max(0.015, outer * 0.42)
        var band = SIMD4<Float>(inner, outer, 0.009, 0.34)
        encoder.setComputePipelineState(compressWakePSO)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightBuffer, offset: 0, index: 1)
        encoder.setBytes(&u, length: uLen, index: 2)
        encoder.setBytes(&band, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        dispatch(encoder, threads: Self.maxParticles, pso: compressWakePSO)

        // Wider soft annulus for a cascading slump.
        var wideBand = SIMD4<Float>(max(0.01, inner * 0.55), min(outer * 1.02, uniforms.fillRadius), 0.005, 0.22)
        encoder.setBytes(&wideBand, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        dispatch(encoder, threads: Self.maxParticles, pso: compressWakePSO)

        for _ in 0..<6 {
            encoder.setComputePipelineState(clearHashPSO)
            encoder.setBuffer(cellHeadBuffer, offset: 0, index: 0)
            encoder.setBytes(&u, length: uLen, index: 1)
            dispatch(encoder, threads: hashCellCount, pso: clearHashPSO)

            encoder.setComputePipelineState(insertHashPSO)
            encoder.setBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setBuffer(cellHeadBuffer, offset: 0, index: 1)
            encoder.setBuffer(nextIndexBuffer, offset: 0, index: 2)
            encoder.setBytes(&u, length: uLen, index: 3)
            dispatch(encoder, threads: Self.maxParticles, pso: insertHashPSO)

            encoder.setComputePipelineState(demPSO)
            encoder.setBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setBuffer(cellHeadBuffer, offset: 0, index: 1)
            encoder.setBuffer(nextIndexBuffer, offset: 0, index: 2)
            encoder.setBytes(&u, length: uLen, index: 3)
            dispatch(encoder, threads: Self.maxParticles, pso: demPSO)
        }

        encoder.setComputePipelineState(relaxPSO)
        encoder.setBuffer(heightBuffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: uLen, index: 1)
        dispatch(encoder, threads: cells, pso: relaxPSO)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        refreshHeightStats()
        publishFillProgressIfNeeded(force: true)
    }

    /// CPU copy of the height field in meters (row-major, `gridResolution²`).
    func sampleHeightFieldMeters() -> [Float] {
        let n = Self.gridResolution * Self.gridResolution
        let ptr = heightBuffer.contents().bindMemory(to: UInt32.self, capacity: n)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = Float(ptr[i]) * 1e-6
        }
        return out
    }

    func setRitualFillFloor(_ progress: Float) {
        let floorH = max(0.03, min(1, progress)) * uniforms.maxHeight
        var floorMicrons = UInt32(floorH * 1e6)
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var u = uniforms
        encoder.setComputePipelineState(raiseFloorPSO)
        encoder.setBuffer(heightBuffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<GrainUniforms>.stride, index: 1)
        encoder.setBytes(&floorMicrons, length: MemoryLayout<UInt32>.stride, index: 2)
        dispatch(encoder, threads: Self.gridResolution * Self.gridResolution, pso: raiseFloorPSO)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        refreshHeightStats()
        publishFillProgressIfNeeded(force: true)
    }

    // MARK: - Metal helpers

    private func dispatch(_ encoder: MTLComputeCommandEncoder, threads: Int, pso: MTLComputePipelineState) {
        let w = pso.threadExecutionWidth
        let tg = MTLSize(width: w, height: 1, depth: 1)
        let groups = MTLSize(width: (threads + w - 1) / w, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
    }

    private func dispatchPulse(center: SIMD2<Float>, radius: Float, heightAdd: Float) {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var u = uniforms
        var pulse = SIMD4<Float>(center.x, center.y, radius, heightAdd)
        encoder.setComputePipelineState(pulsePSO)
        encoder.setBuffer(heightBuffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<GrainUniforms>.stride, index: 1)
        encoder.setBytes(&pulse, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        dispatch(encoder, threads: Self.gridResolution * Self.gridResolution, pso: pulsePSO)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func refreshHeightStats() {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        heightSumBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        var u = uniforms
        encoder.setComputePipelineState(heightSumPSO)
        encoder.setBuffer(heightBuffer, offset: 0, index: 0)
        encoder.setBuffer(heightSumBuffer, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<GrainUniforms>.stride, index: 2)
        dispatch(encoder, threads: Self.gridResolution * Self.gridResolution, pso: heightSumPSO)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let sum = heightSumBuffer.contents().load(as: UInt32.self)
        let cellCount = UInt32(Self.gridResolution * Self.gridResolution)
        cachedSurfaceY = Float(sum / max(cellCount, 1)) * 1e-6
        fillProgress = max(0.03, min(1, cachedSurfaceY / max(uniforms.maxHeight, 1e-4)))
    }

    private func publishFillProgressIfNeeded(force: Bool) {
        guard force || abs(fillProgress - lastPublishedProgress) >= 0.008,
              let host = hostEntity,
              let tierRoot = findTierRoot(from: host) else { return }
        lastPublishedProgress = fillProgress
        MandalaBuilder.setTierFillProgress(
            tierEntity: tierRoot,
            progress: fillProgress,
            animated: false
        )
    }

    private func findTierRoot(from entity: Entity) -> Entity? {
        var node: Entity? = entity
        while let current = node {
            if current.name.hasPrefix("Tier_") { return current }
            node = current.parent
        }
        return nil
    }

    private func updateMeshParts(billboardCount: Int) {
        let fillR = uniforms.fillRadius
        let peak = max(cachedSurfaceY * 1.15, 0.01)
        surfaceMesh?.parts[0] = LowLevelMesh.Part(
            indexCount: (Self.gridResolution - 1) * (Self.gridResolution - 1) * 6,
            topology: .triangle,
            materialIndex: 0,
            bounds: BoundingBox(
                min: SIMD3(-fillR, 0, -fillR),
                max: SIMD3(fillR, peak, fillR)
            )
        )
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

    private func buildMeshesIfNeeded() throws {
        if surfaceMesh == nil {
            let res = Self.gridResolution
            var desc = LowLevelMesh.Descriptor()
            desc.vertexCapacity = res * res
            desc.indexCapacity = (res - 1) * (res - 1) * 6
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

            mesh.replaceUnsafeMutableIndices { raw in
                let indices = raw.bindMemory(to: UInt32.self)
                var cursor = 0
                for z in 0..<(res - 1) {
                    for x in 0..<(res - 1) {
                        let i0 = UInt32(z * res + x)
                        let i1 = i0 + 1
                        let i2 = UInt32((z + 1) * res + x)
                        let i3 = i2 + 1
                        indices[cursor] = i0; indices[cursor + 1] = i2; indices[cursor + 2] = i1
                        indices[cursor + 3] = i1; indices[cursor + 4] = i2; indices[cursor + 5] = i3
                        cursor += 6
                    }
                }
            }

            mesh.parts.replaceAll([
                LowLevelMesh.Part(
                    indexCount: (res - 1) * (res - 1) * 6,
                    topology: .triangle,
                    materialIndex: 0,
                    bounds: BoundingBox(
                        min: SIMD3(-uniforms.fillRadius, 0, -uniforms.fillRadius),
                        max: SIMD3(uniforms.fillRadius, uniforms.maxHeight, uniforms.fillRadius)
                    )
                )
            ])
            surfaceMesh = mesh
            let resource = try MeshResource(from: mesh)
            var mat = SimpleMaterial()
            mat.color = .init(tint: UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1))
            mat.roughness = .float(0.9)
            mat.metallic = .float(0.02)
            let model = ModelEntity(mesh: resource, materials: [mat])
            model.name = "GPUHeightFieldSurface"
            surfaceEntity = model
        }

        if particleMesh == nil {
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
            mat.color = .init(tint: UIColor(red: 0.99, green: 0.97, blue: 0.93, alpha: 1))
            mat.roughness = .float(0.85)
            let model = ModelEntity(mesh: resource, materials: [mat])
            model.name = "GPUGrainParticles"
            particleEntity = model
        }
    }
}
