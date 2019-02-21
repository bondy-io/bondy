

# Module bondy_wamp_utils #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#maybe_error-2">maybe_error/2</a></td><td>Returns a CALL RESULT or ERROR based on the first Argument.</td></tr><tr><td valign="top"><a href="#no_such_procedure_error-1">no_such_procedure_error/1</a></td><td>Creates a wamp_error() based on a wamp_call().</td></tr><tr><td valign="top"><a href="#no_such_registration_error-1">no_such_registration_error/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

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

