local collections = require(script.Parent._Index["larsen-dev_collections@0.1.1"]["collections"])

export type set<T> = collections.set<T>
export type stack<T> = collections.stack<T>
export type queue<T> = collections.queue<T>

return collections
