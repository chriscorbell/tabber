import Foundation

// Each module's probe is one case below: tabber-probe <module> [options].
let probeArguments = Array(CommandLine.arguments.dropFirst())

switch probeArguments.first {
case "overlay": runOverlayProbe(Array(probeArguments.dropFirst()))
case "input": runInputProbe(Array(probeArguments.dropFirst()))
case "ax": runAXProbe(Array(probeArguments.dropFirst()))
case "context": runContextProbe(Array(probeArguments.dropFirst()))
default:
    print("usage: tabber-probe <module> [options]")
    print("  overlay   ghost-text window (tabber-probe overlay help)")
}
