--!strict

-- Dependecies
local signal = require(script.Packages.signal)
local collections = require(script.Packages.collections)

-- Functions

local function default<context>(context: context): boolean
	return true
end

-- State
local state = {}
state._prototype = {}
state.__index = state._prototype

type stateData = {
	name: string,
	interruptible: boolean,
}

type statePrototype<context, args...> = {
	onEnter: (self: state<context, args...>, context: context) -> ()?,
	onLeave: (self: state<context, args...>, context: context) -> ()?,
	update: (self: state<context, args...>, context: context, args...) -> ()?,
}

export type state<context, args...> = typeof(setmetatable(
	{} :: stateData,
	{ __index = {} :: statePrototype<context, args...> }
))

function state.new<context, args...>(name: string, interruptible: boolean): state<context, args...>
	return setmetatable({
		name = name,
		interruptible = interruptible,
	}, state) :: state<context, args...>
end

-- StateMachine
local stateMachine = {}
stateMachine._prototype = {}
stateMachine.__index = stateMachine._prototype

type stateMachineData<context, args...> = {
	_previous: state<context, args...>?,
	_current: state<context, args...>?,
	_states: { [string]: state<context, args...> },
	_transitions: { [string]: { [string]: { condition: (context: context) -> boolean } } },
	_transitioning: boolean,
	_pending: collections.queue<string>,

	context: context,
	transitioned: signal.Signal<string, string>,
	entered: signal.Signal<string>,
	left: signal.Signal<string>,
	transitionFailed: signal.Signal<string, context>,
}

type stateMachinePrototype<context, args...> = {
	registerState: (self: stateMachine<context, args...>, st: state<context, args...>) -> (),
	registerTransition: (
		self: stateMachine<context, args...>,
		from: string,
		to: string,
		condition: ((context: context) -> boolean)?
	) -> (),
	registerGlobalTransition: (
		self: stateMachine<context, args...>,
		to: string,
		condition: ((context: context) -> boolean)?
	) -> (),
	canTransition: (self: stateMachine<context, args...>, from: string, to: string) -> boolean,
	canTransitionNow: (self: stateMachine<context, args...>, from: string, to: string) -> boolean,
	requestTransition: (self: stateMachine<context, args...>, to: string, delay: number?) -> (),
	forceTransition: (self: stateMachine<context, args...>, to: string) -> (),
	bindUpdate: (
		self: stateMachine<context, args...>,
		to: RBXScriptSignal | signal.Signal<args...>
	) -> RBXScriptConnection | signal.Connection<args...>,
	bindTransition: (
		self: stateMachine<context, args...>,
		to: RBXScriptSignal | signal.Signal<args...>,
		fromState: string,
		toState: string
	) -> (RBXScriptConnection | signal.Connection<args...>)?,
}

export type stateMachine<context, args...> = typeof(setmetatable(
	{} :: stateMachineData<context, args...>,
	{ __index = {} :: stateMachinePrototype<context, args...> }
))

function stateMachine._prototype:registerState<context, args...>(st: state<context, args...>)
	self._states[st.name] = st
end

function stateMachine._prototype:registerTransition<context>(
	from: string,
	to: string,
	condition: ((context: context) -> boolean)?
)
	if not self._transitions[from] then
		self._transitions[from] = {}
	end

	self._transitions[from][to] = {
		condition = condition or default,
	}
end

function stateMachine._prototype:registerGlobalTransition<context>(to: string, condition: ((context: context) -> boolean)?)
	condition = condition or default

	for name, _ in pairs(self._states) do
		if not self._transitions[name] then
			self._transitions[name] = {}
		end

		self._transitions[name][to] = {
			condition = condition,
		}
	end
end

function stateMachine._prototype:canTransition(from: string, to: string): boolean
	local t = self._transitions[from] and self._transitions[from][to]
	return t ~= nil
end

function stateMachine._prototype:canTransitionNow(from: string, to: string): boolean
	if self._transitioning then
		return false
	end

	local t = self._transitions[from] and self._transitions[from][to]
	return t ~= nil and t.condition(self.context)
end

function stateMachine._prototype:requestTransition(to: string, delay: number?)
	if delay then
		task.delay(delay, function()
			self._pending:enqueue(to)
		end)
	else
		self._pending:enqueue(to)
	end
end

function stateMachine._prototype:_transition(to: string)
	local current = self._current
	if current and not current.interruptible then
		return
	end

	if current and not self:canTransitionNow(current.name, to) then
		self.transitionFailed:Fire(string.format('Can\'t transition to "%s" at current time.', to), self.context)
		warn(string.format('Can\'t transition to "%s" at current time.', to), self.context)
		return
	end

	local nextState = self._states[to]

	if not nextState then
		self.transitionFailed:Fire(string.format('Unknown state "%s"', to), self.context)
		warn(string.format('Unknown state "%s"', to))
		return
	end

	self._transitioning = true

	if current and current.onLeave then
		current:onLeave(self.context)
	end

	local fromName = if current then current.name else ""
	self.left:Fire(fromName)

	self._previous = self._current
	self._current = nextState

	if nextState.onEnter then
		nextState:onEnter(self.context)
	end
	self.entered:Fire(to)

	self._transitioning = false
	self.transitioned:Fire(fromName, to)
end

function stateMachine._prototype:forceTransition(to: string)
	local current = self._current
	local nextState = self._states[to]

	if not nextState then
		self.transitionFailed:Fire(string.format('Unknown state "%s"', to), self.context)
		warn(string.format('Unknown state "%s"', to))
		return
	end

	self._transitioning = true

	if current and current.onLeave then
		current:onLeave(self.context)
	end

	local fromName = if current then current.name else ""
	self.left:Fire(fromName)

	self._previous = self._current
	self._current = nextState

	if nextState.onEnter then
		nextState:onEnter(self.context)
	end
	self.entered:Fire(to)

	self._transitioning = false
	self.transitioned:Fire(fromName, to)
end

function stateMachine._prototype:bindUpdate<Args...>(
	to: RBXScriptSignal | signal.Signal<Args...>
): RBXScriptConnection | signal.Connection<Args...>
	return to:Connect(function(...: Args...)
		if self._current and self._current.update then
			self._current:update(self.context, ...)
		end

		if
			not self._pending:isEmpty()
			and (not self._current or self:canTransitionNow(self._current.name, self._pending:peek()))
		then
			local nextState = self._pending:dequeue()

			self:_transition(nextState)
		end
	end)
end

function stateMachine._prototype:bindTransition<Args...>(
	to: RBXScriptSignal | signal.Signal<Args...>,
	fromState: string,
	toState: string
): (RBXScriptConnection | signal.Connection<Args...>)?
	if not self:canTransition(fromState, toState) then
		return
	end

	return to:Connect(function(_)
		if not self._current or self._current.name ~= fromState then
			return
		end

		self:requestTransition(toState)
	end)
end

function stateMachine.new<context, args...>(context: context): stateMachine<context, args...>
	return setmetatable({
		_states = {},
		_transitions = {},
		_current = nil,
		_previous = nil,
		_transitioning = false,
		_pending = collections.newQueue() :: collections.queue<string>,

		context = context,
		transitioned = signal.new() :: signal.Signal<string, string>,
		transitionFailed = signal.new() :: signal.Signal<string, context>,
		entered = signal.new() :: signal.Signal<string>,
		left = signal.new() :: signal.Signal<string>,
	}, stateMachine) :: stateMachine<context, args...>
end

return table.freeze({
	newState = state.new,
	newStateMachine = stateMachine.new,
})
