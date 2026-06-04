import Foundation

/// Claude (やシェル) の出力ストリームから PR URL を抽出するための純粋ロジック。
///
/// `https://github.com/<owner>/<repo>/pull/<number>` のパターンを検出する。
/// 抽出済みの URL は内部で記憶し、同じ PR を二度返さない (= 出力の重複を吸収する)。
public final class PRLinkExtractor {

    public init() {}

    private var seen: Set<URL> = []

    /// 出力チャンクから新規に検出された PR URL を返す。
    /// すでに `seen` に入っている PR は除外される。
    public func extractNew(from chunk: String) -> [URL] {
        let urls = Self.matchAll(in: chunk)
        var fresh: [URL] = []
        for url in urls where !seen.contains(url) {
            seen.insert(url)
            fresh.append(url)
        }
        return fresh
    }

    /// 内部状態を捨ててリセット。新しいペイン/セッション開始時に呼ぶ。
    public func reset() {
        seen.removeAll()
    }

    /// 静的ヘルパ: テキスト全体から PR URL 全件を抽出 (重複なし、出現順)。
    public static func matchAll(in text: String) -> [URL] {
        // path: /<owner>/<repo>/pull/<digits>
        // owner/repo はアルファベット数字 _ - .
        // 末尾の数字はクエリやアンカー (#issuecomment-...) で終了
        let pattern = #"https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        var result: [URL] = []
        var seen: Set<URL> = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let str = ns.substring(with: match.range)
            guard let url = URL(string: str), !seen.contains(url) else { return }
            seen.insert(url)
            result.append(url)
        }
        return result
    }
}
