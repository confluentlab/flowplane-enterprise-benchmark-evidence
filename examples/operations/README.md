# Operations starter example

This small fixture demonstrates a representative set of deterministic Flowplane transformations. It is designed for quick simulation or runtime smoke testing. The complete operation-by-operation catalog is in [Operations and transformations](../../docs/operations-and-transformations.md).

Use [input.json](input.json) as the source payload and [mapping.yml](mapping.yml) as the mapping. A successful transformation produces [expected-output.json](expected-output.json) with no field errors.

The [verification record](verification.json) captures the runtime revision, test result, and hashes of the three fixtures without publishing implementation-source mappings.

The fixture deliberately excludes nondeterministic values (`uuid`, `now`, and encryption ciphertext) from the exact-output comparison. Their syntax and behavior are documented in the catalog and covered by the runtime contract verification.
