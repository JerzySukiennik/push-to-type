import Foundation

/// Carries a value into a closure that is declared `@Sendable` but is in fact invoked
/// synchronously, on the calling thread, before the enclosing call returns.
///
/// `AVAudioConverter`'s input block is the case this exists for: it is annotated
/// `@Sendable`, yet the converter drives it inline from `convert(to:error:)`. Each instance
/// is confined to a single such call, so no synchronisation is needed. The box makes that
/// reasoning explicit and local, instead of silencing a whole file with a
/// `@preconcurrency` import.
final class CallLocal<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
