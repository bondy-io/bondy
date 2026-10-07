---- MODULE ConfirmedCompaction_TTrace_1791493433 ----
EXTENDS Sequences, ConfirmedCompaction_TEConstants, TLCExt, Toolbox, Naturals, TLC, ConfirmedCompaction

_expression ==
    LET ConfirmedCompaction_TEExpression == INSTANCE ConfirmedCompaction_TEExpression
    IN ConfirmedCompaction_TEExpression!expression
----

_trace ==
    LET ConfirmedCompaction_TETrace == INSTANCE ConfirmedCompaction_TETrace
    IN ConfirmedCompaction_TETrace!trace
----

_prop ==
    ~(([]<>(
            vv = (<<<<<<0, 0>>, <<2, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>)
            /\
            durable = (<<<<2, 2>>, <<2, 2>>>>)
            /\
            applied = (<<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>)
            /\
            wm = (<<[org |-> 1, seq |-> 2], [org |-> 1, seq |-> 2]>>)
            /\
            link = (<<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>)
            /\
            tree = (<<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>)
            /\
            minted = (<<2, 2>>)
            /\
            retired = ({})
            /\
            fresh = (<<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>)
            /\
            hlc = (<<<<1, 3>>, <<1, 2>>>>)
            /\
            cuts = (0)
    ))/\([]<>(
            vv = (<<<<<<0, 0>>, <<2, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>)
            /\
            durable = (<<<<2, 2>>, <<2, 2>>>>)
            /\
            applied = (<<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>)
            /\
            wm = (<<[org |-> 1, seq |-> 2], [org |-> 1, seq |-> 2]>>)
            /\
            link = (<<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>)
            /\
            tree = (<<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {}>>)
            /\
            minted = (<<2, 2>>)
            /\
            retired = ({})
            /\
            fresh = (<<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>)
            /\
            hlc = (<<<<1, 3>>, <<1, 2>>>>)
            /\
            cuts = (0)
    )))
----

_init ==
    /\ fresh = _TETrace[1].fresh
    /\ durable = _TETrace[1].durable
    /\ minted = _TETrace[1].minted
    /\ link = _TETrace[1].link
    /\ tree = _TETrace[1].tree
    /\ applied = _TETrace[1].applied
    /\ cuts = _TETrace[1].cuts
    /\ vv = _TETrace[1].vv
    /\ wm = _TETrace[1].wm
    /\ hlc = _TETrace[1].hlc
    /\ retired = _TETrace[1].retired
----

_next ==
    /\ \E i,j \in DOMAIN _TETrace:
        /\ \/ /\ j = i + 1
              /\ i = TLCGet("level")
           \/ /\ i = _TTraceLassoEnd
              /\ j = _TTraceLassoStart
        /\ fresh  = _TETrace[i].fresh
        /\ fresh' = _TETrace[j].fresh
        /\ durable  = _TETrace[i].durable
        /\ durable' = _TETrace[j].durable
        /\ minted  = _TETrace[i].minted
        /\ minted' = _TETrace[j].minted
        /\ link  = _TETrace[i].link
        /\ link' = _TETrace[j].link
        /\ tree  = _TETrace[i].tree
        /\ tree' = _TETrace[j].tree
        /\ applied  = _TETrace[i].applied
        /\ applied' = _TETrace[j].applied
        /\ cuts  = _TETrace[i].cuts
        /\ cuts' = _TETrace[j].cuts
        /\ vv  = _TETrace[i].vv
        /\ vv' = _TETrace[j].vv
        /\ wm  = _TETrace[i].wm
        /\ wm' = _TETrace[j].wm
        /\ hlc  = _TETrace[i].hlc
        /\ hlc' = _TETrace[j].hlc
        /\ retired  = _TETrace[i].retired
        /\ retired' = _TETrace[j].retired

\* Uncomment the ASSUME below to write the states of the error trace
\* to the given file in Json format. Note that you can pass any tuple
\* to `JsonSerialize`. For example, a sub-sequence of _TETrace.
    \* ASSUME
    \*     LET J == INSTANCE Json
    \*         IN J!JsonSerialize("ConfirmedCompaction_TTrace_1791493433.json", _TETrace)


_view ==
    <<fresh, durable, minted, link, tree, applied, cuts, vv, wm, hlc, retired, IF TLCGet("level") = _TTraceLassoEnd + 1 THEN _TTraceLassoStart ELSE TLCGet("level")>>
=============================================================================

 Note that you can extract this module `ConfirmedCompaction_TEExpression`
  to a dedicated file to reuse `expression` (the module in the 
  dedicated `ConfirmedCompaction_TEExpression.tla` file takes precedence 
  over the module `ConfirmedCompaction_TEExpression` below).

---- MODULE ConfirmedCompaction_TEExpression ----
EXTENDS Sequences, ConfirmedCompaction_TEConstants, TLCExt, Toolbox, Naturals, TLC, ConfirmedCompaction

expression == 
    [
        \* To hide variables of the `ConfirmedCompaction` spec from the error trace,
        \* remove the variables below.  The trace will be written in the order
        \* of the fields of this record.
        fresh |-> fresh
        ,durable |-> durable
        ,minted |-> minted
        ,link |-> link
        ,tree |-> tree
        ,applied |-> applied
        ,cuts |-> cuts
        ,vv |-> vv
        ,wm |-> wm
        ,hlc |-> hlc
        ,retired |-> retired
        
        \* Put additional constant-, state-, and action-level expressions here:
        \* ,_stateNumber |-> _TEPosition
        \* ,_freshUnchanged |-> fresh = fresh'
        
        \* Format the `fresh` variable as Json value.
        \* ,_freshJson |->
        \*     LET J == INSTANCE Json
        \*     IN J!ToJson(fresh)
        
        \* Lastly, you may build expressions over arbitrary sets of states by
        \* leveraging the _TETrace operator.  For example, this is how to
        \* count the number of times a spec variable changed up to the current
        \* state in the trace.
        \* ,_freshModCount |->
        \*     LET F[s \in DOMAIN _TETrace] ==
        \*         IF s = 1 THEN 0
        \*         ELSE IF _TETrace[s].fresh # _TETrace[s-1].fresh
        \*             THEN 1 + F[s-1] ELSE F[s-1]
        \*     IN F[_TEPosition - 1]
    ]

=============================================================================



Parsing and semantic processing can take forever if the trace below is long.
 In this case, it is advised to uncomment the module below to deserialize the
 trace from a generated binary file.

\*
\*---- MODULE ConfirmedCompaction_TETrace ----
\*EXTENDS IOUtils, ConfirmedCompaction_TEConstants, TLC, ConfirmedCompaction
\*
\*trace == IODeserialize("ConfirmedCompaction_TTrace_1791493433.bin", TRUE)
\*
\*=============================================================================
\*

---- MODULE ConfirmedCompaction_TETrace ----
EXTENDS ConfirmedCompaction_TEConstants, TLC, ConfirmedCompaction

trace == 
    <<
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,durable |-> <<<<0, 0>>, <<0, 0>>>>,applied |-> <<{}, {}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{}, {}>>,minted |-> <<0, 0>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<0, 0>>, <<0, 0>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,durable |-> <<<<0, 0>>, <<0, 0>>>>,applied |-> <<{[org |-> 1, seq |-> 1]}, {}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1]}, {}>>,minted |-> <<1, 0>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 0>>, <<0, 0>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,durable |-> <<<<0, 0>>, <<0, 0>>>>,applied |-> <<{[org |-> 1, seq |-> 1]}, {[org |-> 2, seq |-> 1]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1]}, {[org |-> 2, seq |-> 1]}>>,minted |-> <<1, 1>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 0>>, <<1, 0>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,durable |-> <<<<0, 0>>, <<0, 0>>>>,applied |-> <<{[org |-> 1, seq |-> 1]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<1, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 0>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,durable |-> <<<<0, 0>>, <<0, 0>>>>,applied |-> <<{[org |-> 1, seq |-> 1]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<1, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 0>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,durable |-> <<<<0, 0>>, <<0, 0>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<1, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 0>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,durable |-> <<<<0, 0>>, <<0, 0>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<0, 0>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<0, 0>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<0, 0>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<2, 2>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<2, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<2, 2>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<2, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<2, 2>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 1, seq |-> 2], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<2, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<2, 2>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 1, seq |-> 2], [org |-> 0, seq |-> 0]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<2, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<2, 2>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 1, seq |-> 2], [org |-> 1, seq |-> 2]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<2, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<2, 2>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 1, seq |-> 2], [org |-> 1, seq |-> 2]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<2, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<2, 2>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 1, seq |-> 2], [org |-> 1, seq |-> 2]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<2, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>,durable |-> <<<<2, 2>>, <<2, 2>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,wm |-> <<[org |-> 1, seq |-> 2], [org |-> 1, seq |-> 2]>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 3>>, <<1, 2>>>>,cuts |-> 0])
    >>
----


=============================================================================

---- MODULE ConfirmedCompaction_TEConstants ----
EXTENDS ConfirmedCompaction

CONSTANTS _TTraceLassoStart, _TTraceLassoEnd

=============================================================================

---- CONFIG ConfirmedCompaction_TTrace_1791493433 ----
CONSTANTS
    Replicas = { 1 , 2 }
    MaxSeq = 2
    Skew = 0
    AsyncApply = TRUE
    Witnesses = "members"
    MaxCuts = 0
    MaxRetire = 0
    DoorRule = "keep"
    MaxDepth = 0
    CapAtUnapplied = TRUE
_TTraceLassoStart = 15
_TTraceLassoEnd = 18

PROPERTY
    _prop

CHECK_DEADLOCK
    \* CHECK_DEADLOCK off because of PROPERTY or INVARIANT above.
    FALSE

INIT
    _init

NEXT
    _next

VIEW
    _view

CONSTANT
    _TETrace <- _trace

ALIAS
    _expression
=============================================================================
\* Generated on Thu Oct 08 22:04:43 BST 2026