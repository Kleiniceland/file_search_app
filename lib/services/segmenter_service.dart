import 'package:jieba_flutter/analysis/jieba_segmenter.dart';
import 'package:jieba_flutter/jieba_flutter.dart';

class SegmenterService {
  JiebaSegmenter? _segmenter;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  Future<void> init() async {
    try {
      await JiebaSegmenter.init();
      _segmenter = JiebaSegmenter();
      _initialized = true;
    } catch (e) {
      _initialized = false;
    }
  }

  List<String> segment(String text) {
    if (_segmenter == null) return [];
    final tokens = _segmenter!.process(text, SegMode.SEARCH);
    // 假设 tokens 中的元素是 SegToken，具有 word 属性
    return tokens.map<String>((token) => token.word).toList();
  }
}
