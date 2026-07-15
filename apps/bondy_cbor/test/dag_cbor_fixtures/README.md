# DAG-CBOR cross-codec fixtures

Vendored from the IPLD cross-codec fixtures suite:
<https://github.com/ipld/codec-fixtures> (commit `a312b720a4f8302c60f075aa3d33149967a4aa45`).

Each `<name>.dag-cbor` file is the canonical DAG-CBOR encoding of a fixture
(taken from `fixtures/<name>/<cid>.dag-cbor` upstream). They are used by
`bondy_cbor_dag_tests` to verify that every fixture decodes and re-encodes to
identical bytes (the cross-codec round-trip methodology). See
<https://ipld.io/specs/codecs/dag-cbor/fixtures/cross-codec/>.
