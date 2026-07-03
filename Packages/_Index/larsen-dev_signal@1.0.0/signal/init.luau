--!strict

-- Values
local taskSpawn = task.spawn
local tableInsert = table.insert
local tableRemove = table.remove
local tableUnpack = table.unpack
local tablePack = table.pack
local threadPool = {} :: { thread }

local MAX_RUNNERS = 32

-- Functions

--[=[
	@return thread;

	Acquires unused threads which could be reused or creates new one if there's no such and stores another running into
	threadPool.
]=]
local function acquireRunner(): thread
	local amount = #threadPool

	if amount > 0 then
		return tableRemove(threadPool, amount) :: thread
	end

	local runner = coroutine.create(function(callback, args)
		while true do
			local success, errorMessage = xpcall(callback, debug.traceback, tableUnpack(args))

			if not success then
				warn(errorMessage)
			end

			if #threadPool < MAX_RUNNERS then
				tableInsert(threadPool, coroutine.running())
			end

			callback, args = coroutine.yield()
		end
	end)

	return runner
end

-- Connection
local connection = {}
connection._prototype = {}
connection.__index = connection._prototype

type ConnectionPrototype<Args...> = {
	Disconnect: (self: Connection<Args...>) -> (),
}

type ConnectionData<Args...> = {
	_signal: Signal<Args...>,
	_next: Connection<Args...>?,
	_previous: Connection<Args...>?,
	_callback: (Args...) -> (),

	Connected: boolean,
}

export type Connection<Args...> = setmetatable<ConnectionData<Args...>, { __index: ConnectionPrototype<Args...> }>

--[=[
	@return ;

	Disconnects connection.
]=]
function connection._prototype:Disconnect()
	if not self.Connected then
		return
	end

	self.Connected = false

	local signal = self._signal
	local next = self._next
	local previous = self._previous

	if next then
		next._previous = previous
	end

	if previous then
		previous._next = next
	end

	if self == signal._head then
		signal._head = if next then next else if previous then previous else nil
	end

	self._signal = nil
	self._callback = nil
	self._previous = nil
	self._next = nil
end

--[=[
	@param signal Signal<Args...>;
	@param callback (Args...) -> ();
	@return Connection<Args...>;

	Creates new Connection metatable.
]=]
function connection.new<Args...>(signal: Signal<Args...>, callback: (Args...) -> ()): Connection<Args...>
	local previous = signal._head

	return setmetatable({
		_signal = signal :: Signal<Args...>?,
		_next = nil :: Connection<Args...>?,
		_previous = previous :: Connection<Args...>?,
		_callback = callback :: (Args...) -> (),

		Connected = true,
	}, connection) :: Connection<Args...>
end

-- Signal
local signal = {}
signal._prototype = {}
signal.__index = signal._prototype

type SignalPrototype<Args...> = {
	Fire: (self: Signal<Args...>, Args...) -> (),
	Connect: (self: Signal<Args...>, callback: (Args...) -> ()) -> Connection<Args...>,
	Once: (self: Signal<Args...>, callback: (Args...) -> ()) -> Connection<Args...>,
	Wait: (self: Signal<Args...>) -> Args...,
	DisconnectAll: (self: Signal<Args...>) -> (),
	Destroy: (self: Signal<Args...>) -> (),
}

type SignalData<Args...> = {
	_head: Connection<Args...>?,
}

export type Signal<Args...> = setmetatable<SignalData<Args...>, { __index: SignalPrototype<Args...> }>

--[=[
	@param ... Args...;
	@return ;

	Fires all connections' callbacks.
]=]
function signal._prototype:Fire(...)
	local node = self._head
	local args = tablePack(...)

	while node do
		taskSpawn(acquireRunner(), node._callback, args)

		node = node._previous
	end
end

--[=[
	@param ... Args...;
	@return ;

	Fires all connections' callbacks at the end of resumption cycle.
]=]
function signal._prototype:FireDeferred(...)
	local args = tablePack(...)

	task.defer(function()
		self:Fire(table.unpack(args, 1, args.n))
	end)
end

--[=[
	@param callback (Args...) -> ();
	@return Connection<Args...>;

	Creates Connection metatable with passed callback linked to Signal.
]=]
function signal._prototype:Connect<Args...>(callback: (Args...) -> ()): Connection<Args...>
	local newConnection = connection.new(self, callback)
	local head = self._head

	if head then
		head._next = newConnection
	end
	self._head = newConnection

	return newConnection
end

--[=[
	@param callback (Args...) -> ();
	@return Connection<Args...>;

	Connects the callback and returns a Connection that automatically 
	disconnects itself after the first time the signal is fired.
]=]
function signal._prototype:Once<Args...>(callback: (Args...) -> ()): Connection<Args...>
	local newConnection
	newConnection = connection.new(self, function(...: Args...)
		newConnection:Disconnect()
		callback(...)
	end)
	local head = self._head

	if head then
		head._next = newConnection
	end
	self._head = newConnection

	return newConnection
end

--[=[
	@return Args...;

	Returns arguments passed through :Fire() method. Yields current thread until fire.
]=]
function signal._prototype:Wait<Args...>(): Args...
	local freeThread = coroutine.running()

	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		taskSpawn(freeThread, ...)
	end)

	return coroutine.yield()
end

--[=[
	@return ;

	Disconnects all connections linked to Signal;
]=]
function signal._prototype:DisconnectAll()
	local node = self._head

	while node do
		local previous = node._previous

		node.Connected = false
		node._signal = nil
		node._next = nil
		node._previous = nil
		node._callback = nil

		node = previous
	end

	self._head = nil
end

--[=[
	@return ;

	Unsets metatable, cleaning all links to Signal and disconnects all connections, so
	GC could collect all of them.
]=]
function signal._prototype:Destroy()
	self:DisconnectAll()
	setmetatable(self, nil)
end

--[=[
	@return Signal<Args...>;

	Creates new Signal metatable;
]=]
function signal.new<Args...>(): Signal<Args...>
	return setmetatable({
		_head = nil :: Connection<Args...>?,
	}, signal) :: Signal<Args...>
end

return table.freeze(signal)
