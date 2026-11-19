# Third-party notices

Tea Three's natural voices run entirely on the phone. The model and voices are
not in this repository: `scripts/fetch-voices.sh` downloads them at build time
from pinned URLs, verifies each against `scripts/pocket-tts.sha256`, and
`ios-build.sh` embeds them in the app.

| Component | Use | License |
| --- | --- | --- |
| [Pocket TTS](https://huggingface.co/kyutai/pocket-tts) (english_2026-09) by Kyutai | Natural voice model, converted to Core ML by [MB Books](https://github.com/Marginally-Better-Apps/mb-books) (transformer weights quantized to 8 bits, sampling loop restructured for Core ML) | CC BY 4.0 |
| Pocket TTS tokenizer by Kyutai | `App/Resources/Speech/pocket-tokenizer.json` | CC BY 4.0 |
| [Kyutai TTS voices](https://huggingface.co/kyutai/tts-voices) | Precomputed voice prompts | CC0 and CC BY 4.0, per voice |
| [CSTR VCTK Corpus](https://datashare.ed.ac.uk/handle/10283/3443) (Veaux, Yamagishi, MacDonald, University of Edinburgh) | Behind Anna, Azelma, Charles, Eponine, Eve, Fantine, George, Jane, Mary, Michael, Paul, Vera | CC BY 4.0 |
| Alba MacKenna's recordings | Alba | CC BY 4.0 |
| [Voice-Zero](https://github.com/OwenTyme/voice-zero) (LibriVox narrators Bill Boerst, Caro Davy, Peter Yearsley, Stuart Bell) | Bill, Caro, Peter, Stuart | CC0 |
| MB Books speech code | `App/Sources/Voice/Pocket/*.swift` (Pocket TTS runtime, tokenizer, English normalization) | From MB Books |

CC BY 4.0: https://creativecommons.org/licenses/by/4.0/legalcode
CC0 1.0: https://creativecommons.org/publicdomain/zero/1.0/legalcode
