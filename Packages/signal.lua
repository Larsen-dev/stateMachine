local signal = require(script.Parent._Index["larsen-dev_signal@1.0.0"]["signal"])

export type Connection<Args...> = signal.Connection<Args...>
export type Signal<Args...> = signal.Signal<Args...>

return signal
