--!strict

-- Dependecies
local signal = require(script.Packages.signal)
local collections = require(script.Packages.collections)

-- Functions

-- Default guard function.
local function default<context>(context: context): (boolean, string?)
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

--[=[
	@return state<context, args...>;
	@param name string;
	@param interruptible boolean?;

	Creates new state metatable. Interruptible decides whether transition
	from this state will be possible, default to false.
]=]
function state.new<context, args...>(name: string, interruptible: boolean?): state<context, args...>
	return setmetatable({
		name = name,
		interruptible = interruptible or true,
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
	_transitions: { [string]: { [string]: { guard: (context: context) -> (boolean, string?) } } },
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
		guard: ((context: context) -> (boolean, string?))?
	) -> (),
	registerGlobalTransition: (
		self: stateMachine<context, args...>,
		to: string,
		guard: ((context: context) -> (boolean, string?))?
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

--[=[
	@return ;
	@param st state<context, args...>;

	Registers new state to state machine.
]=]
function stateMachine._prototype:registerState<context, args...>(st: state<context, args...>)
	self._states[st.name] = st
end

--[=[
	@return ;
	@param from string;
	@param to string;
	@param guard ((context: context) -> (boolean, string?))?;

	Registers transitions from some state to other.
]=]
function stateMachine._prototype:registerTransition<context>(
	from: string,
	to: string,
	guard: ((context: context) -> (boolean, string?))?
)
	if not self._transitions[from] then
		self._transitions[from] = {}
	end

	self._transitions[from][to] = {
		guard = guard or default,
	}
end

--[=[
	@return ;
	@param to string;
	@param guard ((context: context) -> (boolean, string?))?;

	Registers transition to some transition from all registered states.
]=]
function stateMachine._prototype:registerGlobalTransition<context>(
	to: string,
	guard: ((context: context) -> (boolean, string?))?
)
	guard = guard or default

	for name, _ in pairs(self._states) do
		if not self._transitions[name] then
			self._transitions[name] = {}
		end

		self._transitions[name][to] = {
			guard = guard,
		}
	end
end

--[=[
	@return boolean;
	@param from string;
	@param to string;

	Checks whether transition is possible from some state to other.
]=]
function stateMachine._prototype:canTransition(from: string, to: string): boolean
	local t = self._transitions[from] and self._transitions[from][to]
	return t ~= nil
end

--[=[
	@return boolean, string?;
	@param from string;
	@param to string;

	Checks whether transition from some state to some state is possible at
	the current moment. Returns whethere machine can transition and a reason
	if not.
]=]
function stateMachine._prototype:canTransitionNow(from: string, to: string): (boolean, string?)
	if self._transitioning then
		return false, "Machine is transitioning to other state."
	end

	local transitions = self._transitions[from]
	if not transitions then
		return false, "Unknown transition."
	end

	local transition = transitions[to]
	if not transition then
		return false, "Transition not registered."
	end

	return transition.guard(self.context)
end

--[=[
	@return ;
	@param to string;
	@param delay number?;

	Adds some transition into request queue with possible delay.
]=]
function stateMachine._prototype:requestTransition(to: string, delay: number?)
	if delay then
		task.delay(delay, function()
			self._pending:enqueue(to)
		end)
	else
		self._pending:enqueue(to)
	end
end

--[=[
	@return ;
	@param to string;

	Basic transition logic.
]=]
function stateMachine._prototype:_transition(to: string)
	local current = self._current
	if current and not current.interruptible then
		return
	end

	local can, reason = if current then self:canTransitionNow(current.name, to) else nil, nil

	if not can then
		self.transitionFailed:Fire(reason, self.context)
		warn(string.format('Can\'t transition to "%s" at current time. Reason: %s', to, tostring(reason)))
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

--[=[
	@return ;
	@param to string;

	Forces transition to some state ignoring current cycle and guards
]=]
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

--[=[
	@return RBXScriptConnection | Connection<Args...>;
	@param to RBXScriptSignal | Signal<Args...>;

	Binds machine update cycle to some signal object.
]=]
function stateMachine._prototype:bindUpdate<Args...>(
	to: RBXScriptSignal | signal.Signal<Args...>
): RBXScriptConnection | signal.Connection<Args...>
	return to:Connect(function(...: Args...)
		if self._current and self._current.update then
			self._current:update(self.context, ...)
		end

		local can, reason =
			if self._current then self:canTransitionNow(self._current.name, self._pending:peek()) else nil, nil
		warn(string.format('Can\'t transition to "%s" at current time. Reason: %s', to, tostring(reason)))

		if not self._pending:isEmpty() and can then
			local nextState = self._pending:dequeue()

			self:_transition(nextState)
		end
	end)
end

--[=[
	@return RBXScriptConnection | Connection<Args...>;
	@param to RBXScriptSignal | Signal<Args...>;
	@param fromState string;
	@param toState string;

	Binds transition from some state to another to some signal
	object.
]=]
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

--[=[
	@return stateMachine<context, args...>;
	@param context context;

	Creates new stateMachine metatable.
]=]
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
