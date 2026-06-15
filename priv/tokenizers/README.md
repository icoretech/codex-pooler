# Tokenizer Rank Data

This directory stores local tokenizer rank data used by
`CodexPooler.Gateway.RequestCompression.TokenCounter`.

The `.tiktoken` files are OpenAI tiktoken mergeable-rank tables downloaded from:

- `https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken`
- `https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken`

They are data tables, not model weights. Runtime token counting is local,
CPU-only, and does not call OpenAI or any network service.

The BPE implementation is project-owned code informed by the public `tiktoken`
format and the MIT-licensed `tiktokenex` package shape. Keep the bundled license
files with these assets:

- `LICENSE.tiktoken`
- `LICENSE.tiktokenex`
