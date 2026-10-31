--!strict

-- Dependecies
local signal = require(script.Packages.signal)
local collections = require(script.Packages.collections)

-- Functions

-- Default guard function.
local function default<context>(context: context): (boolean, string?)
	return true, nil
end

-- State
type stateData = {
	name: string,
	interruptible: boolean,
}

type statePrototype<context = { [string]: number }, args... = ...any> = {
	onEnter: (self: state<context, args...>, context: context) -> ()?,
	onLeave: (self: state<context, args...>, context: context) -> ()?,
	update: (self: state<context, args...>, context: context, args...) -> ()?,
}

export type state<context = { [string]: number }, args... = ...any> = setmetatable<
	stateData,
	{ __index: statePrototype<context, args...> }
>

local state = {}
state._prototype = {} :: statePrototype<>
state.__index = state._prototype

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
export type transitionData<context = { [string]: number }> = {
	guard: (context: context) -> (boolean, string?),
	onTransition: ((context: context) -> ())?,
	force: boolean,
}

type stateMachineData<context = { [string]: number }, args... = ...any> = {
	_previous: state<context, args...>?,
	_current: state<context, args...>?,
	_states: { [string]: state<context, args...> },
	_transitions: { [string]: { [string]: transitionData<context> } },
	_transitioning: boolean,
	_pending: collections.queue<string>,

	context: context,
	transitioned: signal.Signal<(from: string, to: string) -> (), string, string>,
	entered: signal.Signal<(to: string) -> (), string>,
	left: signal.Signal<(from: string) -> (), string>,
	transitionFailed: signal.Signal<(reason: string, context: context) -> (), string, context>,
}

type stateMachinePrototype<context = { [string]: number }, args... = ...any> = {
	registerState: (self: stateMachine<context, args...>, st: state<context, args...>) -> (),
	registerTransition: (
		self: stateMachine<context, args...>,
		from: string,
		to: string,
		data: transitionData<context>
	) -> (),
	registerGlobalTransition: (
		self: stateMachine<context, args...>,
		to: string,
		data: transitionData<context>
	) -> (),
	canTransition: (self: stateMachine<context, args...>, from: string, to: string) -> boolean,
	canTransitionNow: (self: stateMachine<context, args...>, from: string, to: string) -> boolean,
	requestTransition: (self: stateMachine<context, args...>, to: string, delay: number?) -> (),
	forceTransition: (self: stateMachine<context, args...>, to: string) -> (),
	currentName: (self: stateMachine<context, args...>) -> string?,
	previousName: (self: stateMachine<context, args...>) -> string?,
	setInitialState: (self: stateMachine<context, args...>, to: string) -> (),
	bindUpdate: (
		self: stateMachine<context, args...>,
		to: RBXScriptSignal | signal.Signal<(context: string) -> (), string>
	) -> RBXScriptConnection | signal.Signal<(context: string) -> (), string>,
	bindTransition: (
		self: stateMachine<context, args...>,
		to: RBXScriptSignal | signal.Signal<(context: string) -> (), string>,
		fromState: string,
		toState: string
	) -> (RBXScriptConnection | signal.Connection<(context) -> (), string>)?,
	_transition: (self: stateMachine<context, args...>, to: string) -> (),
}

export type stateMachine<context = { [string]: number }, args... = ...any> = setmetatable<
	stateMachineData<context, args...>,
	{ __index: stateMachinePrototype<context, args...> }
>

local stateMachine = {}
stateMachine._prototype = {} :: stateMachinePrototype<>
stateMachine.__index = stateMachine._prototype

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
	@param guard: ((context: context) -> (boolean, string?))?;
	@param onTransition: ((context: context) -> ())?;
	@param force: boolean?;

	Registers transitions from some state to other.
]=]
function stateMachine._prototype:registerTransition<context>(
	from: string,
	to: string,
	guard: ((context: context) -> (boolean, string?))?,
	onTransition: ((context: context) -> ())?,
	force: boolean?
)
	if not self._states[from] or not self._states[to] then
		return
	end

	local data = {
		guard = guard or default,
		onTransition = onTransition,
		force = force or false,
	} :: transitionData<context>

	if not self._transitions[from] then
		self._transitions[from] = {}
	end

	self._transitions[from][to] = data
end

--[=[
	@return ;
	@param to string;
	@param guard: ((context: context) -> (boolean, string?))?;
	@param onTransition: ((context: context) -> ())?;
	@param force: boolean?;

	Registers transition to some transition from all registered states.
]=]
function stateMachine._prototype:registerGlobalTransition<context>(
	to: string,
	guard: ((context: context) -> (boolean, string?))?,
	onTransition: ((context: context) -> ())?,
	force: boolean?
)
	if not self._states[to] then
		return
	end

	local data = {
		guard = guard or default,
		onTransition = onTransition,
		force = force or false,
	} :: transitionData<context>

	for name, _ in pairs(self._states) do
		if not self._transitions[name] then
			self._transitions[name] = {}
		end

		self._transitions[name][to] = data
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

	local fromState = self._states[from]
	if not fromState.interruptible and not transition.force then
		return false, "Can't transition from non-interruptible state without force."
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
function stateMachine._prototype:_transition<context>(to: string)
	local current = self._current
	if (not current or not current.name) or (current and not current.interruptible) then
		return
	end

	local nextState = self._states[to]
	if not nextState then
		self.transitionFailed:Fire(string.format('Unknown state "%s"', to), self.context)
		warn(string.format('Unknown state "%s"', to))
		return
	end

	local transitionData: transitionData<context> = self._transitions[current.name][to]

	self._transitioning = true

	if current and current.onLeave then
		current:onLeave(self.context)
	end

	local fromName = if current then current.name else ""
	self.left:Fire(fromName)

	self._previous = self._current
	self._current = nextState

	if transitionData.onTransition then
		transitionData.onTransition(self.context)
	end

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
function stateMachine._prototype:forceTransition<context>(to: string, onTransition: ((context: context) -> ())?)
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

	if onTransition then
		onTransition(self.context)
	end

	if nextState.onEnter then
		nextState:onEnter(self.context)
	end
	self.entered:Fire(to)

	self._transitioning = false
	self.transitioned:Fire(fromName, to)
end

--[=[
	@return string?;

	Returns current state's name.
]=]
function stateMachine._prototype:currentName(): string?
	return if self._current then self._current.name else nil
end

--[=[
	@return string?;

	Returns previous state's name.
]=]
function stateMachine._prototype:previousName(): string?
	return if self._previous then self._previous.name else nil
end

--[=[
	@return ;
	@param to string;

	Transitions machine to some state before update cycle
	been binded. Uses insecure :forceTransition(), use only
	before life-cycle been started.
]=]
function stateMachine._prototype:setInitialState(to: string)
	self:forceTransition(to)
end

--[=[
	@return RBXScriptConnection | Connection<args...>;
	@param to RBXScriptSignal | Signal<args...>;

	Binds machine update cycle to some signal object.
]=]
function stateMachine._prototype:bindUpdate<args...>(
	to: RBXScriptSignal | signal.Signal<(args...) -> (), args...>
): RBXScriptConnection | signal.Connection<(args...) -> (), args...>
	return to:Connect(function(...: args...)
		if self._current and self._current.update then
			self._current:update(self.context, ...)
		end

		if self._pending:isEmpty() then
			return
		end

		while not self._pending:isEmpty() do
			local can, reason =
				self._current and self:canTransitionNow(self._current.name, self._pending:peek() :: string) or false,
				nil

			if can then
				local nextState = self._pending:dequeue() :: string
				self:_transition(nextState)
			else
				warn(
					string.format(
						'Can\'t transition to "%s" at current time. Reason: %s',
						self._pending:peek() :: string,
						tostring(reason)
					)
				)

				break
			end
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
function stateMachine._prototype:bindTransition<args...>(
	to: RBXScriptSignal | signal.Signal<(args...) -> (), args...>,
	fromState: string,
	toState: string
): (
	RBXScriptConnection | signal.Connection<(args...) -> (), args...>
)?
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
