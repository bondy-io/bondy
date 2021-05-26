

# Module bondy_consistent_hashing #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

It uses Jump Consistent Hash algorithm described in
[A Fast, Minimal Memory, Consistent Hash Algorithm](https://arxiv.org/ftp/
arxiv/papers/1406/1406.2294.pdf).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#bucket-2">bucket/2</a></td><td></td></tr><tr><td valign="top"><a href="#bucket-3">bucket/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="bucket-2"></a>

### bucket/2 ###

<pre><code>
bucket(Key::term(), Buckets::pos_integer()) -&gt; Bucket::integer()
</code></pre>
<br />

<a name="bucket-3"></a>

### bucket/3 ###

<pre><code>
bucket(Key::term(), Buckets::pos_integer(), Algo::atom()) -&gt; Bucket::integer()
</code></pre>
<br />

