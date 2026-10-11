import Foundation

/// Finds the scene the story starts with the way the game does: `main.kcs` (the boot script)
/// sets up the engine's shared memory and starts `flow.fes`; after GAME START, flow runs
/// `sscript.kcs`, which reads `$512` (-3 for a new game) and loads the scene named by
/// `$str200` (`01`). Both scripts run on `KCSMachine` with `KCSRecordingHost`, sharing memory,
/// until sscript asks for the scene (native `0x145`).
public enum KCSBoot {
    public struct Result: Sendable {
        public let scene: String
        /// Instructions run: main.kcs up to starting flow, then sscript up to the scene load.
        public let mainSteps: Int
        public let sscriptSteps: Int
        public let nativeCalls: Int
        /// The engine variables as the scripts left them.
        public let variables: [Int: Int]
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// `variables` and `strings` are FES's `$n` and `$strN` after the title screen
    /// (`FESPlayer.variables`, `.stringVariables`).
    public static func firstScene(game: CatSystemGame, variables: [Int: Int], strings: [Int: String],
                                  limit: Int = 5_000_000) throws -> Result {
        func script(_ name: String) throws -> KCScript {
            guard let bytes = try game.file(named: name) else { throw Failure(description: "no \(name)") }
            return try KCScript(bytes)
        }
        let host = KCSRecordingHost()
        host.variables = variables
        host.stringVariables = strings

        // main.kcs: run until it starts flow.fes.
        host.stopAt = [0x1BF]
        let main = KCSMachine(script: try script("main.kcs"))
        main.host = host
        while !main.halted, host.stopped == nil, main.steps < limit { try main.step() }
        guard host.stopped != nil else { throw Failure(description: "main.kcs didn't start flow.fes in \(main.steps) steps") }

        // FES ran the title meanwhile: its variables win over what main.kcs set.
        for (k, v) in variables { host.variables[k] = v }
        for (k, v) in strings { host.stringVariables[k] = v }
        host.resetStop([0x145])
        let sscript = KCSMachine(script: try script("sscript.kcs"))
        sscript.host = host
        sscript.sharedMemory = main.sharedMemory
        while !sscript.halted, host.stopped == nil, sscript.steps < limit { try sscript.step() }
        guard let load = host.stopped, load.args.count == 2 else {
            throw Failure(description: "sscript.kcs didn't load a scene in \(sscript.steps) steps")
        }
        return Result(scene: sscript.string(at: load.args[1]), mainSteps: main.steps, sscriptSteps: sscript.steps,
                      nativeCalls: host.calls.count, variables: host.variables)
    }
}
