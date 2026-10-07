---- MODULE ConfirmedCompaction_TTrace_1791554290 ----
EXTENDS Sequences, TLCExt, Toolbox, Naturals, TLC, ConfirmedCompaction

_expression ==
    LET ConfirmedCompaction_TEExpression == INSTANCE ConfirmedCompaction_TEExpression
    IN ConfirmedCompaction_TEExpression!expression
----

_trace ==
    LET ConfirmedCompaction_TETrace == INSTANCE ConfirmedCompaction_TETrace
    IN ConfirmedCompaction_TETrace!trace
----

_prop ==
    ~<>[](
        vv = (<<<<<<0, 0>>, <<0, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>)
        /\
        applied = (<<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>)
        /\
        link = (<<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>)
        /\
        tree = (<<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>)
        /\
        losses = (1)
        /\
        durable = (<<<<0, 0>>, <<0, 0>>>>)
        /\
        lost = (<<{}, {[org |-> 1, seq |-> 1]}>>)
        /\
        wm = (<<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>)
        /\
        minted = (<<2, 2>>)
        /\
        retired = ({})
        /\
        fresh = (<<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>)
        /\
        hlc = (<<<<1, 2>>, <<3, 4>>>>)
        /\
        cuts = (0)
    )
----

_init ==
    /\ fresh = _TETrace[1].fresh
    /\ durable = _TETrace[1].durable
    /\ minted = _TETrace[1].minted
    /\ link = _TETrace[1].link
    /\ tree = _TETrace[1].tree
    /\ applied = _TETrace[1].applied
    /\ losses = _TETrace[1].losses
    /\ lost = _TETrace[1].lost
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
        /\ losses  = _TETrace[i].losses
        /\ losses' = _TETrace[j].losses
        /\ lost  = _TETrace[i].lost
        /\ lost' = _TETrace[j].lost
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
    \*         IN J!JsonSerialize("ConfirmedCompaction_TTrace_1791554290.json", _TETrace)

=============================================================================

 Note that you can extract this module `ConfirmedCompaction_TEExpression`
  to a dedicated file to reuse `expression` (the module in the 
  dedicated `ConfirmedCompaction_TEExpression.tla` file takes precedence 
  over the module `ConfirmedCompaction_TEExpression` below).

---- MODULE ConfirmedCompaction_TEExpression ----
EXTENDS Sequences, TLCExt, Toolbox, Naturals, TLC, ConfirmedCompaction

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
        ,losses |-> losses
        ,lost |-> lost
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
\*EXTENDS IOUtils, TLC, ConfirmedCompaction
\*
\*trace == IODeserialize("ConfirmedCompaction_TTrace_1791554290.bin", TRUE)
\*
\*=============================================================================
\*

---- MODULE ConfirmedCompaction_TETrace ----
EXTENDS TLC, ConfirmedCompaction

trace == 
    <<
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,applied |-> <<{}, {}>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{}, {}>>,losses |-> 0,durable |-> <<<<0, 0>>, <<0, 0>>>>,lost |-> <<{}, {}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,minted |-> <<0, 0>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<0, 0>>, <<0, 0>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,applied |-> <<{[org |-> 1, seq |-> 1]}, {}>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1]}, {}>>,losses |-> 0,durable |-> <<<<0, 0>>, <<0, 0>>>>,lost |-> <<{}, {}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,minted |-> <<1, 0>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 0>>, <<0, 0>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<0, 0>>, <<0, 0>>>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2]}, {}>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2]}, {}>>,losses |-> 0,durable |-> <<<<0, 0>>, <<0, 0>>>>,lost |-> <<{}, {}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,minted |-> <<2, 0>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 2>>, <<0, 0>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<2, 0>>, <<0, 0>>>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2]}, {}>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2]}>>,losses |-> 0,durable |-> <<<<0, 0>>, <<0, 0>>>>,lost |-> <<{}, {}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,minted |-> <<2, 0>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 2>>, <<0, 0>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<2, 0>>, <<0, 0>>>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2]}, {[org |-> 2, seq |-> 1]}>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1]}>>,losses |-> 0,durable |-> <<<<0, 0>>, <<0, 0>>>>,lost |-> <<{}, {}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,minted |-> <<2, 1>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 2>>, <<3, 0>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 0>>>>, <<<<2, 0>>, <<0, 0>>>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,losses |-> 0,durable |-> <<<<0, 0>>, <<0, 0>>>>,lost |-> <<{}, {}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 2>>, <<3, 4>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,losses |-> 0,durable |-> <<<<0, 0>>, <<0, 0>>>>,lost |-> <<{}, {}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 2>>, <<3, 4>>>>,cuts |-> 0]),
    ([vv |-> <<<<<<0, 0>>, <<0, 2>>>>, <<<<2, 2>>, <<0, 0>>>>>>,applied |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,link |-> <<<<TRUE, TRUE>>, <<TRUE, TRUE>>>>,tree |-> <<{[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}, {[org |-> 1, seq |-> 1], [org |-> 1, seq |-> 2], [org |-> 2, seq |-> 1], [org |-> 2, seq |-> 2]}>>,losses |-> 1,durable |-> <<<<0, 0>>, <<0, 0>>>>,lost |-> <<{}, {[org |-> 1, seq |-> 1]}>>,wm |-> <<[org |-> 0, seq |-> 0], [org |-> 0, seq |-> 0]>>,minted |-> <<2, 2>>,retired |-> {},fresh |-> <<<<FALSE, TRUE>>, <<TRUE, FALSE>>>>,hlc |-> <<<<1, 2>>, <<3, 4>>>>,cuts |-> 0])
    >>
----


=============================================================================

---- CONFIG ConfirmedCompaction_TTrace_1791554290 ----
CONSTANTS
    Replicas = { 1 , 2 }
    MaxSeq = 2
    Skew = 0
    AsyncApply = FALSE
    Witnesses = "members"
    MaxCuts = 0
    MaxRetire = 0
    DoorRule = "confirmed"
    MaxDepth = 0
    CapAtUnapplied = TRUE
    MaxLost = 1
    WalkLost = FALSE
    HealGate = "off"
    HealCap = TRUE
    FusedHold = TRUE

PROPERTY
    _prop

CHECK_DEADLOCK
    \* CHECK_DEADLOCK off because of PROPERTY or INVARIANT above.
    FALSE

INIT
    _init

NEXT
    _next

CONSTANT
    _TETrace <- _trace

ALIAS
    _expression
=============================================================================
\* Generated on Fri Oct 09 14:58:14 BST 2026