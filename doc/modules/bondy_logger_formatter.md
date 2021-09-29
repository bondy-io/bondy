

# Module bondy_logger_formatter #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

This is the main module that exposes custom formatting to the OTP
logger library (part of the `kernel` application since OTP-21).

<a name="description"></a>

## Description ##
The module honors the standard configuration of the kernel's default
logger formatter regarding: max depth, templates.
<a name="functions"></a>

## Function Details ##

<a name="format-2"></a>

### format/2 ###

<pre><code>
format(LogEvent, Config) -&gt; <a href="unicode.md#type-chardata">unicode:chardata()</a>
</code></pre>

<ul class="definitions"><li><code>LogEvent = <a href="logger.md#type-log_event">logger:log_event()</a></code></li><li><code>Config = <a href="logger.md#type-formatter_config">logger:formatter_config()</a></code></li></ul>

