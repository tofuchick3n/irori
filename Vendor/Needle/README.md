# Needle engine (Whistle speech to text)

`needle.h` is the header of Cactus Compute's Needle engine, from
[Cactus-Compute/needle3](https://huggingface.co/Cactus-Compute/needle3), under the Apache 2.0 license in
`LICENSE`. The engine itself ships only as a prebuilt library, so it isn't checked in:
`scripts/fetch-whistle` downloads `libneedle.a` and the Whistle weights (`whistle.cact`) into
`.build/whistle` at pinned revisions and checks their SHA-256. Run it once before `swift build`;
`scripts/make-app` runs it for you and bundles the weights.
