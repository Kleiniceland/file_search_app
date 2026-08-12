/// CLIP BPE 分词器
///
/// 用于 MobileCLIP 文本编码器的输入预处理。
/// 实现与 OpenAI CLIP 相同的 byte-level BPE 编码。
library;

import 'dart:convert';
import 'package:flutter/services.dart';

/// CLIP 文本分词器
class ClipTokenizer {
  /// 词汇表：token → ID
  final Map<String, int> _vocab;

  /// BPE 合并规则（按优先级排序）
  final List<List<String>> _merges;

  /// BPE 合并优先级映射 "token1 token2" → rank
  final Map<String, int> _bpeRanks;

  /// Byte → Unicode 字符映射
  final Map<int, String> _byteEncoder;

  /// 特殊 token
  static const int _bosToken = 49406; // <|startoftext|>
  static const int _eosToken = 49407; // <|endoftext|>
  static const int _contextLength = 77;

  ClipTokenizer._(this._vocab, this._merges, this._bpeRanks, this._byteEncoder);

  /// 从 assets 加载分词器
  static Future<ClipTokenizer> fromAssets({
    String vocabPath = 'assets/models/mobileclip_onnx/clip_vocab.json',
    String mergesPath = 'assets/models/mobileclip_onnx/clip_merges.txt',
  }) async {
    // 加载词汇表
    final vocabStr = await rootBundle.loadString(vocabPath);
    final vocab = (jsonDecode(vocabStr) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, v as int));

    // 加载 BPE 合并规则
    final mergesStr = await rootBundle.loadString(mergesPath);
    final merges = mergesStr
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.startsWith('#'))
        .map((l) => l.split(' '))
        .toList();

    // 构建 BPE 优先级映射
    final bpeRanks = <String, int>{};
    for (int i = 0; i < merges.length; i++) {
      bpeRanks['${merges[i][0]} ${merges[i][1]}'] = i;
    }

    // 构建 byte → unicode 映射
    final byteEncoder = _buildByteEncoder();

    return ClipTokenizer._(vocab, merges, bpeRanks, byteEncoder);
  }

  /// 构建 byte-to-unicode 映射（与 CLIP/Python 实现一致）
  static Map<int, String> _buildByteEncoder() {
    final bs = <int>[
      ...List.generate(ord('~') - ord('!') + 1, (i) => ord('!') + i),
      ...List.generate(ord('¬') - ord('¡') + 1, (i) => ord('¡') + i),
      ...List.generate(ord('ÿ') - ord('®') + 1, (i) => ord('®') + i),
    ];
    final cs = List<int>.from(bs);
    int n = 0;
    for (int b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    return {
      for (int i = 0; i < bs.length; i++) bs[i]: String.fromCharCode(cs[i])
    };
  }

  static int ord(String c) => c.codeUnitAt(0);

  /// 文本 → token IDs（BOS + tokens + EOS，填充到 77）
  List<int> encode(String text) {
    // 1. whitespace_clean + 转小写（与 CLIP Python 实现一致）
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

    // 2. 按正则分割（CLIP 标准：不带前导空格，空格会被跳过）
    final tokens = <String>[];
    final regex = RegExp(r"'s|'t|'re|'ve|'m|'ll|'d|[a-z]+|[0-9]+|[^\sa-z0-9]+");
    for (final match in regex.allMatches(text)) {
      tokens.add(match.group(0)!);
    }

    // 3. Byte-level 编码
    final bpeTokens = <int>[];
    for (final token in tokens) {
      // 将每个字符转换为 byte，再映射到 unicode 字符
      final bytes = utf8.encode(token);
      final encoded = bytes.map((b) => _byteEncoder[b]!).join('');

      // 4. BPE 编码
      final bpeResult = _bpe(encoded);
      for (final bpeToken in bpeResult.split(' ')) {
        if (_vocab.containsKey(bpeToken)) {
          bpeTokens.add(_vocab[bpeToken]!);
        }
      }
    }

    // 5. 添加 BOS 和 EOS
    final result = <int>[_bosToken, ...bpeTokens, _eosToken];

    // 6. 截断或填充到 77
    if (result.length > _contextLength) {
      return result.sublist(0, _contextLength - 1)..add(_eosToken);
    }
    while (result.length < _contextLength) {
      result.add(_eosToken);
    }

    return result;
  }

  /// BPE 编码：将字符串通过合并规则转换为 BPE token 序列
  String _bpe(String token) {
    if (token.isEmpty) return '';

    // 将字符串拆分为单个字符，并在最后一个字符后添加 </w>（与 GPT-2/CLIP BPE 一致）
    // 这样 BPE 合并后的 token 形如 "red</w>"，才能在词表中匹配到 ID 736
    var word = token.split('');
    word[word.length - 1] = word.last + '</w>';
    var pairs = _getPairs(word);

    // 单字符 token 无相邻对可合并，直接返回带 </w> 的形式（如 "a</w>" → ID 320）
    if (pairs.isEmpty) return word.join(' ');

    while (true) {
      // 找到优先级最高（rank 最小）的 pair
      int? minRank;
      List<String>? minPair;
      for (final pair in pairs) {
        final rank = _bpeRanks[pair.join(' ')];
        if (rank != null && (minRank == null || rank < minRank)) {
          minRank = rank;
          minPair = pair;
        }
      }

      if (minPair == null) break;

      // 合并所有该 pair
      final first = minPair[0];
      final second = minPair[1];
      final newWord = <String>[];
      int i = 0;
      while (i < word.length) {
        final j = word.indexOf(first, i);
        if (j == -1) {
          newWord.addAll(word.sublist(i));
          break;
        }
        newWord.addAll(word.sublist(i, j));
        i = j;

        if (i < word.length - 1 && word[i] == first && word[i + 1] == second) {
          newWord.add(first + second);
          i += 2;
        } else {
          newWord.add(word[i]);
          i += 1;
        }
      }
      word = newWord;
      if (word.length == 1) break;
      pairs = _getPairs(word);
    }

    return word.join(' ');
  }

  /// 获取相邻字符对
  List<List<String>> _getPairs(List<String> word) {
    final pairs = <List<String>>[];
    for (int i = 0; i < word.length - 1; i++) {
      pairs.add([word[i], word[i + 1]]);
    }
    return pairs;
  }

  /// 生成 attention mask（全 1，因为 padding 用 EOS 而非 PAD）
  List<int> attentionMask(int length) {
    return List.filled(length, 1);
  }
}
