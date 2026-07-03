-- Dependecies
local signal = require(script.Packages.signal)
--local collections = require(script.Packages.collections)

-- Functions

local function default<context>(_: context)
	return true
end

-- State
local state = {}
state._prototype = {}
state.__index = state._prototype

type StateData = {
	name: string,
}

type StatePrototype<context, args...> = {
	onEnter: (self: State<context, args...>, context: context) -> ()?,
	onLeave: (self: State<context, args...>, context: context) -> ()?,
	update: (self: State<context, args...>, context: context, args...) -> ()?,
	lock: (self: State<context, args...>) -> (),
	unlock: (self: State<context, args...>) -> (),
}

export type State<context, args...> = setmetatable<StateData, { __index: StatePrototype<context, args...> }>

function state.new<context, args...>(name: string): State<context, args...>
	return setmetatable({
		name = name,
	}, state) :: State<context, args...>
end

-- StateMachine
local stateMachine = {}
stateMachine._prototype = {}
stateMachine.__index = stateMachine._prototype

type StateMachineData<context, args...> = {
	_current: State<context, args...>?,
	_states: { [string]: State<context, args...> },
	_transitions: { [string]: { [string]: { can: boolean, condition: (context: context) -> boolean } } },
	_transitioning: boolean,
	_pending: string?,

	context: context,
	transitioned: signal.Signal<string, string>,
	transitionFailed: signal.Signal<string, context>,
}

type StateMachinePrototype<context, args...> = {
	registerState: (self: StateMachine<context, args...>, st: State<context, args...>) -> (),
	registerTransition: (
		self: StateMachine<context, args...>,
		from: string,
		to: string,
		condition: ((context: context) -> boolean)?
	) -> (),
	canTransition: (self: StateMachine<context, args...>, from: string, to: string) -> boolean,
	canTransitionNow: (self: StateMachine<context, args...>, from: string, to: string) -> boolean,
	requestTransition: (self: StateMachine<context, args...>, to: string) -> (),
	bindUpdate: (
		self: StateMachine<context, args...>,
		to: RBXScriptSignal | signal.Signal<args...>
	) -> RBXScriptConnection | signal.Connection<args...>,
	bindTransition: (
		self: StateMachine<context, args...>,
		to: RBXScriptSignal | signal.Signal<args...>,
		fromState: string,
		toState: string
	) -> (RBXScriptConnection | signal.Connection<args...>)?,
}

export type StateMachine<context, args...> = setmetatable<
	StateMachineData<context, args...>,
	{ __index: StateMachinePrototype<context, args...> }
>

function stateMachine._prototype:registerState<context, args...>(st: State<context, args...>)
	self._states[st.name] = st
end

function stateMachine._prototype:registerTransition<context>(from: string, to: string, condition: (context: context) -> boolean)
	if not self._transitions[from] then
		self._transitions[from] = {}
	end
	self._transitions[from][to] = {
		can = true,
		condition = condition or default,
	}
end

function stateMachine._prototype:canTransition(from: string, to: string): boolean
	return self._transitions[from] and self._transitions[from][to] and self._transitions[from][to]["can"]
end

function stateMachine._prototype:canTransitionNow(from: string, to: string): boolean
	return not self._transitioning
		and self._transitions[from]
		and self._transitions[from][to]
		and self._transitions[from][to]["can"]
		and self._transitions[from][to]["condition"](self.context)
end

function stateMachine._prototype:requestTransition(to: string)
	self._pending = to
end

function stateMachine._prototype:_transition(to: string)
	local current = self._current
	if current and not self:canTransitionNow(current.name, to) then
		self.transitionFailed:Fire(string.format("Failed transition to %s.", to), self.context)
		return
	end

	local nextState = self._states[to]
	if not nextState then
		return
	end

	self._transitioning = true

	if current and current.onLeave then
		current:onLeave(self.context)
	end

	local fromName = if current then current.name else ""

	self._current = nextState

	if nextState.onEnter then
		nextState:onEnter(self.context)
	end

	self._transitioning = false

	self.transitioned:Fire(fromName, to)
end

function stateMachine._prototype:bindUpdate<Args...>(
	to: RBXScriptSignal | signal.Signal<Args...>
): RBXScriptConnection | signal.Connection<Args...>
	return to:Connect(function(...: Args...)
		if self._pending and (not self._current or self:canTransitionNow(self._current.name, self._pending)) then
			local nextState = self._pending :: string?
			self._pending = nil

			self:_transition(nextState)
		end

		if not self._current or not self._current.update then
			return
		end
		self._current:update(self.context, ...)
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

		self:transition(toState)
	end)
end

function stateMachine.new<context, args...>(context: context): StateMachine<context, args...>
	return setmetatable({
		_states = {},
		_transitions = {},
		_current = nil,
		_transitioning = false,
		_pending = nil,

		context = context,
		transitioned = signal.new() :: signal.Signal<args...>,
	}, stateMachine) :: StateMachine<context, args...>
end

return table.freeze({
	newState = state.new,
	newStateMachine = stateMachine.new,
})
