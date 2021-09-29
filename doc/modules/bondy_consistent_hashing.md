

# Module bondy_consistent_hashing #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)

It uses Jump Consistent Hash algorithm described in
[A Fast, Minimal Memory, Consistent Hash Algorithm](https://arxiv.org/ftp/
arxiv/papers/1406/1406.2294.pdf).

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

