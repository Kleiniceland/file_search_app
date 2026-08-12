import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../services/embedding_engine.dart';
import '../services/vector_store.dart';
import '../services/search_service.dart';
import '../services/pipeline_service.dart';
import '../utils/file_reader_factory.dart';
import '../utils/file_utils.dart';
import 'dart:convert';

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _queryController = TextEditingController();

  // 服务实例
  EmbeddingEngine? _engine;
  VectorStore? _vectorStore;
  SearchService? _searchService;
  PipelineService? _pipelineService;

  // 初始化状态
  bool _isInitializing = true;
  String _initStatus = '正在加载模型...';

  // 索引状态
  bool _isIndexing = false;
  String _indexStatus = '';
  int _indexTotal = 0;
  int _indexCurrent = 0;

  // 搜索状态
  bool _isSearching = false;
  List<HybridSearchResult> _searchResults = [];
  String _searchStatus = '';

  // 搜索目录
  String _searchDirectory =
      Platform.environment['HOME'] ?? Directory.current.path;

  // 扩展名筛选
  Set<String> _selectedExtensions = {...supportedExtensions};

  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _queryController.dispose();
    _engine?.dispose();
    super.dispose();
  }

  /// 初始化所有服务
  Future<void> _initializeServices() async {
    try {
      setState(() => _initStatus = '正在加载 BERT 模型...');

      // 1. 加载嵌入引擎（中文 BERT + MobileCLIP 图像）
      // MobileCLIP 文本编码器延迟加载（避免同时加载 3 个模型导致内存不足）
      final projectRoot = Directory.current.path;
      _engine = await EmbeddingEngine.initChinese(
        imageModelPath:
            '$projectRoot/assets/models/mobileclip_onnx/image_encoder.onnx',
      );

      setState(() => _initStatus = '正在初始化向量存储...');

      // 2. 初始化向量存储
      _vectorStore = VectorStore();
      await _vectorStore!.init();

      // 3. 创建搜索服务和管道服务
      _searchService = SearchService(
        engine: _engine!,
        vectorStore: _vectorStore!,
      );
      _pipelineService = PipelineService(
        engine: _engine!,
        vectorStore: _vectorStore!,
      );

      setState(() {
        _isInitializing = false;
        _initStatus = '就绪 (已索引 ${_vectorStore!.count} 个文件)';
      });

      // 4. 异步延迟加载 MobileCLIP 文本编码器（用于跨模态搜索）
      _engine!
          .loadClipTextEncoder(
        '$projectRoot/assets/models/mobileclip_onnx/text_encoder.onnx',
      )
          .then((ok) {
        if (mounted && ok) {
          setState(() {
            _initStatus = '就绪 (已索引 ${_vectorStore!.count} 个文件, 跨模态搜索已启用)';
          });
        }
      });
    } catch (e) {
      setState(() {
        _isInitializing = false;
        _initStatus = '❌ 初始化失败: $e';
      });
    }
  }

  /// 索引目录
  Future<void> _indexDirectory() async {
    final pipeline = _pipelineService;
    if (pipeline == null) return;

    setState(() {
      _isIndexing = true;
      _indexStatus = '正在扫描目录...';
      _indexCurrent = 0;
      _indexTotal = 0;
    });

    try {
      final stats = await pipeline.indexDirectory(
        _searchDirectory,
        onProgress: (current, total, fileName, error) {
          if (mounted) {
            setState(() {
              _indexCurrent = current;
              _indexTotal = total;
              if (error != null) {
                _indexStatus = '索引失败: $fileName ($error)';
              } else {
                _indexStatus = '正在索引: $fileName ($current/$total)';
              }
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexStatus =
              '✅ 索引完成: ${stats.success} 成功, ${stats.skipped} 跳过, ${stats.failed} 失败, 耗时 ${stats.elapsed.inSeconds}s';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isIndexing = false;
          _indexStatus = '❌ 索引出错: $e';
        });
      }
    }
  }

  void _onSearch({bool immediate = false}) {
    if (_isSearching || _searchService == null) return;

    if (!immediate) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
        _performSearch();
      });
      return;
    }
    _performSearch();
  }

  /// 执行混合语义搜索
  Future<void> _performSearch() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _searchStatus = '';
      });
      return;
    }

    final searchService = _searchService;
    if (searchService == null) return;

    setState(() {
      _isSearching = true;
      _searchResults = [];
      _searchStatus = '正在搜索...';
    });

    try {
      final results = await searchService.search(
        query,
        topK: 20,
      );

      // 按选中的扩展名筛选
      final filtered = results.where((r) {
        final ext = r.filePath.split('.').last.toLowerCase();
        return _selectedExtensions.contains(ext);
      }).toList();

      if (mounted) {
        setState(() {
          _isSearching = false;
          _searchResults = filtered;
          _searchStatus =
              filtered.isEmpty ? '未找到匹配文件' : '找到 ${filtered.length} 个结果';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _searchStatus = '❌ 搜索失败: $e';
        });
      }
    }
  }

  Future<void> _pickDirectory() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择搜索文件夹',
      initialDirectory: _searchDirectory,
    );
    if (selectedDirectory != null) {
      setState(() {
        _searchDirectory = selectedDirectory;
      });
    }
  }

  String _getFriendlyPath(String path) {
    if (path.length > 50) {
      return '...' + path.substring(path.length - 47);
    }
    return path;
  }

  Future<void> _openFile(File file) async {
    try {
      final ext = file.path.split('.').last.toLowerCase();
      String text = '';

      if (ext == 'txt') {
        try {
          text = await file.readAsString(encoding: utf8);
        } catch (_) {
          text = await file.readAsString();
        }
      } else {
        final reader = FileReaderFactory.getReader(file.path);
        if (reader == null) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('不支持预览 .$ext 格式文件')),
          );
          return;
        }
        final bytes = await file.readAsBytes();
        text = await reader.read(bytes);
        if (text.isEmpty) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('该文件无可提取的文本内容')),
          );
          return;
        }
      }

      if (!context.mounted) return;
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('文件内容 - ${p.basename(file.path)}'),
          content: SingleChildScrollView(
            child: SelectableText(text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取文件失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 初始化中
    if (_isInitializing) {
      return Scaffold(
        body: Center(
          child: Semantics(
            label: '正在初始化, $_initStatus',
            liveRegion: true,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_initStatus, style: const TextStyle(fontSize: 16)),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('文件语义搜索'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: '选择搜索目录',
            onPressed: _isIndexing ? null : _pickDirectory,
          ),
          IconButton(
            icon: const Icon(Icons.build_circle),
            tooltip: '索引当前目录',
            onPressed: _isIndexing ? null : _indexDirectory,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // 搜索目录显示
            Semantics(
              label:
                  '搜索目录: $_searchDirectory, 已索引 ${_vectorStore?.count ?? 0} 个文件',
              container: true,
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child: const Icon(Icons.folder,
                          size: 20, color: Colors.blue),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '搜索目录',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey[700]),
                          ),
                          Text(
                            _getFriendlyPath(_searchDirectory),
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    ExcludeSemantics(
                      child: Text(
                        '${_vectorStore?.count ?? 0} 文件已索引',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.green[700],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // 搜索框
            TextField(
              controller: _queryController,
              decoration: InputDecoration(
                hintText: '输入搜索内容（支持语义搜索）...',
                labelText: '搜索',
                prefixIcon: const Icon(Icons.search),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: _isSearching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: '清除搜索',
                        onPressed: () {
                          _queryController.clear();
                          setState(() {
                            _searchResults = [];
                            _searchStatus = '';
                          });
                        },
                      ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _onSearch(immediate: true),
              onChanged: (_) => _onSearch(),
            ),
            const SizedBox(height: 8),

            // 扩展名筛选
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: supportedExtensions.map((ext) {
                final selected = _selectedExtensions.contains(ext);
                return FilterChip(
                  label: Text(
                    ext.toUpperCase(),
                    style: TextStyle(
                      fontWeight:
                          selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  selected: selected,
                  selectedColor: Colors.deepPurple.shade200,
                  checkmarkColor: Colors.deepPurple,
                  onSelected: _isSearching
                      ? null
                      : (value) {
                          setState(() {
                            if (value) {
                              _selectedExtensions.add(ext);
                            } else {
                              _selectedExtensions.remove(ext);
                            }
                          });
                          _onSearch();
                        },
                );
              }).toList(),
            ),
            const SizedBox(height: 8),

            // 索引进度
            if (_isIndexing) ...[
              LinearProgressIndicator(
                value: _indexTotal > 0 ? _indexCurrent / _indexTotal : null,
                semanticsLabel: _indexStatus,
              ),
              const SizedBox(height: 4),
              Semantics(
                liveRegion: true,
                child: Text(_indexStatus,
                    style: TextStyle(fontSize: 12, color: Colors.orange[700])),
              ),
            ] else if (_indexStatus.isNotEmpty) ...[
              Semantics(
                liveRegion: true,
                child: Text(_indexStatus,
                    style: TextStyle(fontSize: 12, color: Colors.green[700])),
              ),
            ],

            // 搜索状态
            if (_isSearching || _searchStatus.isNotEmpty) ...[
              const SizedBox(height: 4),
              Semantics(
                liveRegion: true,
                child: Text(
                  _searchStatus,
                  style: TextStyle(
                    fontSize: 12,
                    color: _searchResults.isEmpty
                        ? Colors.grey[700]
                        : Colors.green[700],
                  ),
                ),
              ),
            ],

            const SizedBox(height: 8),

            // 搜索结果列表
            Expanded(
              child: _searchResults.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ExcludeSemantics(
                            child: Icon(
                              _queryController.text.isEmpty
                                  ? Icons.search_off
                                  : Icons.folder_off,
                              size: 48,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _queryController.text.isEmpty
                                ? '请输入搜索内容'
                                : _searchStatus.isEmpty
                                    ? '请先索引目录'
                                    : '未找到匹配文件',
                            style: TextStyle(
                                color: Colors.grey[700], fontSize: 16),
                          ),
                        ],
                      ),
                    )
                  : Semantics(
                      container: true,
                      label: '搜索结果列表，共 ${_searchResults.length} 个结果',
                      child: ListView.builder(
                        itemCount: _searchResults.length,
                        itemBuilder: (context, index) {
                          final result = _searchResults[index];
                          final matchPercent =
                              (result.finalScore * 100).toStringAsFixed(0);
                          final vecPercent =
                              (result.vectorScore * 100).toStringAsFixed(0);
                          final kwPercent =
                              (result.keywordScore * 100).toStringAsFixed(0);

                          // 构建无障碍描述
                          final semanticLabel = StringBuffer()
                            ..write('结果 ${index + 1}: ${result.fileName}')
                            ..write(', 匹配度 $matchPercent%')
                            ..write(', 语义 $vecPercent%, 关键词 $kwPercent%');
                          if (result.contentSnippet.isNotEmpty) {
                            semanticLabel
                                .write(', 内容: ${result.contentSnippet}');
                          }

                          return Semantics(
                            label: semanticLabel.toString(),
                            button: true,
                            hint: '点击打开文件',
                            child: Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: ListTile(
                                leading: ExcludeSemantics(
                                  child: Icon(
                                    _iconForFile(result.filePath),
                                    color: _colorForFile(result.filePath),
                                    size: 36,
                                  ),
                                ),
                                title: Text(
                                  result.fileName,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w500),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (result.contentSnippet.isNotEmpty)
                                      Text(
                                        result.contentSnippet,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[700],
                                        ),
                                      ),
                                    const SizedBox(height: 2),
                                    Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: '匹配度: $matchPercent%  ',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: result.finalScore > 0.5
                                                  ? Colors.deepOrange
                                                  : Colors.grey[700],
                                            ),
                                          ),
                                          TextSpan(
                                            text:
                                                '语义: $vecPercent%  关键词: $kwPercent%',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.open_in_new),
                                  tooltip: '打开 ${result.fileName}',
                                  onPressed: () =>
                                      _openFile(File(result.filePath)),
                                ),
                                onTap: () => _openFile(File(result.filePath)),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForFile(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'txt':
        return Icons.description;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'png':
      case 'jpg':
      case 'jpeg':
        return Icons.image;
      case 'doc':
      case 'docx':
        return Icons.article;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _colorForFile(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'txt':
        return Colors.blueGrey;
      case 'pdf':
        return Colors.redAccent;
      case 'png':
      case 'jpg':
      case 'jpeg':
        return Colors.green;
      case 'doc':
      case 'docx':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }
}
