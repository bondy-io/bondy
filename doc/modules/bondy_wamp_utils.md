

# Module bondy_wamp_utils #
* [Function Index](#index)
* [Function Details](#functions)

<a name="functions"></a>

## Function Details ##

<a name="error-2"></a>

### error/2 ###

`error(Reason, Call) -> any()`

<a name="maybe_error-2"></a>

### maybe_error/2 ###

`maybe_error(Error, Call) -> any()`

Returns a CALL RESULT or ERROR based on the first Argument

<a name="no_such_procedure_error-1"></a>

### no_such_procedure_error/1 ###

`no_such_procedure_error(Call) -> any()`

Creates a wamp_error() based on a wamp_call().

<a name="no_such_registration_error-1"></a>

### no_such_registration_error/1 ###

`no_such_registration_error(RegId) -> any()`

<a name="no_such_session_error-1"></a>

### no_such_session_error/1 ###

`no_such_session_error(SessionId) -> any()`

<a name="validate_admin_call_args-3"></a>

### validate_admin_call_args/3 ###

`validate_admin_call_args(Msg, Ctxt, Min) -> any()`

@throws wamp_message:error()

<a name="validate_admin_call_args-4"></a>

### validate_admin_call_args/4 ###

`validate_admin_call_args(Msg, Ctxt, Min, Max) -> any()`

@throws wamp_message:error()

<a name="validate_call_args-3"></a>

### validate_call_args/3 ###

`validate_call_args(Msg, Ctxt, Min) -> any()`

@throws wamp_message:error()

<a name="validate_call_args-4"></a>

### validate_call_args/4 ###

`validate_call_args(Msg, Ctxt, Min, Max) -> any()`

@throws wamp_message:error()

