import Foundation

/// The game's E-mote characters, loaded from `psz.int` on demand and drawn per pose, with
/// the last few models and drawings kept (a large model keeps ~35 MB of texture).
public final class EmoteCast: @unchecked Sendable {
    public let profiles: EmoteProfiles
    private let files: (String) -> [UInt8]?
    private let lock = NSLock()
    private var renderers: [(name: String, renderer: EmoteRenderer)] = []
    private var drawings: [(key: String, image: EmoteImage)] = []
    public var modelLimit = 5
    public var drawingLimit = 12

    public init(files: @escaping (String) -> [UInt8]?) {
        self.files = files
        profiles = EmoteProfiles(files: files)
    }

    public convenience init(game: CatSystemGame) {
        self.init(files: { try? game.file(named: $0) })
    }

    /// A model by PSB name (`ca01_l_body_1`), or nil when the game has no such file.
    public func renderer(_ name: String) -> EmoteRenderer? {
        lock.lock()
        defer { lock.unlock() }
        if let i = renderers.firstIndex(where: { $0.name == name }) {
            let hit = renderers.remove(at: i)
            renderers.append(hit)
            return hit.renderer
        }
        guard let bytes = files(name + ".psz"), let psb = try? PSBFile(psz: bytes),
              let model = try? EmoteModel(psb: psb) else { return nil }
        let renderer = EmoteRenderer(model: model)
        renderers.append((name, renderer))
        if renderers.count > modelLimit { renderers.removeFirst(renderers.count - modelLimit) }
        return renderer
    }

    /// A character drawn for `spec` (`ca01,1,1,b,3,0,4`) and `m2body` digits, at `scale`
    /// times its profile's scale. `pose` says where the model's origin goes.
    public func draw(_ spec: String, body: [String], scale: Double) -> (image: EmoteImage, pose: EmoteProfiles.Pose)? {
        guard let pose = lock.withLock({ profiles.pose(spec, body: body) }) else { return nil }
        let total = pose.scaleX * scale
        let key = "\(pose.model)|\(pose.variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))|\(total)"
        lock.lock()
        if let hit = drawings.first(where: { $0.key == key }) {
            lock.unlock()
            return (hit.image, pose)
        }
        lock.unlock()
        guard let renderer = renderer(pose.model) else { return nil }
        var variables = renderer.model.restingVariables()
        for (k, v) in pose.variables { variables[k] = v }
        renderer.model.applySelectors(&variables)
        let image = renderer.render(variables: variables, scale: total)
        lock.lock()
        drawings.append((key, image))
        if drawings.count > drawingLimit { drawings.removeFirst(drawings.count - drawingLimit) }
        lock.unlock()
        return (image, pose)
    }
}
