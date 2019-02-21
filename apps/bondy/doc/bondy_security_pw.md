

# Module bondy_security_pw #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#check_password-2">check_password/2</a></td><td></td></tr><tr><td valign="top"><a href="#check_password-5">check_password/5</a></td><td></td></tr><tr><td valign="top"><a href="#hash_password-1">hash_password/1</a></td><td>Hash a plaintext password, returning hashed password and algorithm details.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="check_password-2"></a>

### check_password/2 ###

`check_password(BinaryPass, Password) -> any()`

<a name="check_password-5"></a>

### check_password/5 ###

`check_password(BinaryPass, HashedPassword, HashFunction, Salt, HashIterations) -> any()`

<a name="hash_password-1"></a>

### hash_password/1 ###

`hash_password(BinaryPass) -> any()`

Hash a plaintext password, returning hashed password and algorithm details

