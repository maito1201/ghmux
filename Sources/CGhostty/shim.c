// CGhostty は libghostty (GhosttyKit.xcframework) の C ヘッダを Swift へ公開するための
// ラッパーターゲット。実装シンボルは xcframework がリンク時に供給するため、ここは空でよい。
// SwiftPM がソースを 1 つ要求するため、ヘッダの自己完結性チェックを兼ねた空ファイルを置く。
#include "ghostty.h"
