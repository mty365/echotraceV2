import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:path/path.dart' as path;
import 'package:pointycastle/export.dart';
import 'package:file_picker/file_picker.dart';
import 'wx_key_dll_injector.dart';
import 'wx_key_logger.dart';

class ImageKeyResult {
  final int? xorKey;
  final String? aesKey;
  final String? error;
  final bool success;
  final bool needManualSelection;

  ImageKeyResult.success(this.xorKey, this.aesKey)
      : success = true,
        error = null,
        needManualSelection = false;

  ImageKeyResult.failure(this.error, {this.needManualSelection = false})
      : success = false,
        xorKey = null,
        aesKey = null;
}

class ImageKeyService {
  static Future<String?> getWeChatCacheDirectory({
    String? rootPath,
    String? preferredWxid,
  }) async {
    final directories = await findWeChatCacheDirectories(
      rootPath: rootPath,
      preferredWxid: preferredWxid,
    );
    if (directories.isEmpty) {
      return null;
    }
    return directories.first;
  }

  static Future<List<String>> findWeChatCacheDirectories({
    String? rootPath,
    String? preferredWxid,
  }) async {
    try {
      Directory wechatFilesDir;
      if (rootPath != null && rootPath.trim().isNotEmpty) {
        wechatFilesDir = Directory(rootPath);
      } else {
        final documentsPath = Platform.environment['USERPROFILE'];
        if (documentsPath == null) {
          return [];
        }
        final wechatFilesPath =
            path.join(documentsPath, 'Documents', 'xwechat_files');
        wechatFilesDir = Directory(wechatFilesPath);
      }

      if (!await wechatFilesDir.exists()) {
        return [];
      }

      if (await _directoryHasDbStorage(wechatFilesDir) ||
          await _directoryHasImageCache(wechatFilesDir)) {
        return [wechatFilesDir.path];
      }

      final highConfidence = <String>[];
      final lowConfidence = <String>[];

      final normalizedPreferred = _normalizeWxid(preferredWxid);
      if (normalizedPreferred != null && normalizedPreferred.isNotEmpty) {
        final preferredDir = await _findPreferredWxidDir(
          wechatFilesDir,
          normalizedPreferred,
        );
        if (preferredDir != null) {
          return [preferredDir];
        }
      }

      await for (var entity
          in wechatFilesDir.list(recursive: false, followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }

        final dirName = path.basename(entity.path);
        if (!_isPotentialAccountDirectory(dirName)) {
          continue;
        }

        final hasDbStorage = await _directoryHasDbStorage(entity);
        final hasImageCache = await _directoryHasImageCache(entity);

        if (hasDbStorage || hasImageCache) {
          highConfidence.add(entity.path);
        } else {
          lowConfidence.add(entity.path);
        }
      }

      if (highConfidence.isNotEmpty) {
        highConfidence.sort(
          (a, b) => path.basename(a).compareTo(path.basename(b)),
        );
        return highConfidence;
      }

      lowConfidence.sort(
        (a, b) => path.basename(a).compareTo(path.basename(b)),
      );
      return lowConfidence;
    } catch (e, _) {
      return [];
    }
  }

  static String? _normalizeWxid(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final cleaned = trimmed.replaceFirst(RegExp(r'_[a-zA-Z0-9]{4}$'), '');
    final lower = cleaned.toLowerCase();
    if (!lower.startsWith('wxid_')) return lower;
    final match =
        RegExp(r'^(wxid_[^_]+)', caseSensitive: false).firstMatch(cleaned);
    if (match != null) return match.group(1)!.toLowerCase();
    return lower;
  }

  static Future<String?> _findPreferredWxidDir(
    Directory rootDir,
    String normalizedPreferred,
  ) async {
    await for (var entity
        in rootDir.list(recursive: false, followLinks: false)) {
      if (entity is! Directory) continue;
      final dirName = path.basename(entity.path);
      final normalizedDir = _normalizeWxid(dirName);
      if (normalizedDir == null) continue;
      if (normalizedDir == normalizedPreferred) {
        return entity.path;
      }
    }
    return null;
  }

  static bool _isPotentialAccountDirectory(String dirName) {
    final lower = dirName.toLowerCase();
    if (lower.startsWith('all') ||
        lower.startsWith('applet') ||
        lower.startsWith('backup') ||
        lower.startsWith('wmpf')) {
      return false;
    }

    return dirName.startsWith('wxid_') || dirName.length > 5;
  }

  static Future<bool> _directoryHasDbStorage(Directory directory) async {
    try {
      final dbStoragePath = path.join(directory.path, 'db_storage');
      final dbStorageDir = Directory(dbStoragePath);
      return await dbStorageDir.exists();
    } catch (e) {
      return false;
    }
  }

  static Future<bool> _directoryHasImageCache(Directory directory) async {
    try {
      final imagePath = path.join(directory.path, 'FileStorage', 'Image');
      final imageDir = Directory(imagePath);
      return await imageDir.exists();
    } catch (e) {
      return false;
    }
  }

  static Future<List<File>> _findTemplateDatFiles(String userDir) async {
    final files = <File>[];
    try {
      const int maxFiles = 32;
      final userDirEntity = Directory(userDir);
      if (!await userDirEntity.exists()) {
        return [];
      }

      await for (var entity in userDirEntity.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          final fileName = path.basename(entity.path);
          if (fileName.endsWith('_t.dat')) {
            files.add(entity);
            if (files.length >= maxFiles) {
              break;
            }
          }
        }
      }

      if (files.isEmpty) {
        return [];
      }

      files.sort((a, b) {
        final pathA = a.path;
        final pathB = b.path;
        final regExp = RegExp(r'(\d{4}-\d{2})');
        final matchA = regExp.firstMatch(pathA);
        final matchB = regExp.firstMatch(pathB);
        if (matchA != null && matchB != null) {
          return matchB.group(1)!.compareTo(matchA.group(1)!);
        }
        return 0;
      });

      return files.take(16).toList();
    } catch (e, _) {
      return [];
    }
  }

  static Future<int?> _getXorKey(List<File> templateFiles) async {
    try {
      final lastBytesMap = <String, int>{};

      for (var file in templateFiles) {
        try {
          final bytes = await file.readAsBytes();
          if (bytes.length >= 2) {
            final lastTwo = bytes.sublist(bytes.length - 2);
            final key = '${lastTwo[0]}_${lastTwo[1]}';
            lastBytesMap[key] = (lastBytesMap[key] ?? 0) + 1;
          }
        } catch (e) {
          continue;
        }
      }

      if (lastBytesMap.isEmpty) {
        return null;
      }

      var maxCount = 0;
      String? mostCommon;
      lastBytesMap.forEach((key, count) {
        if (count > maxCount) {
          maxCount = count;
          mostCommon = key;
        }
      });

      if (mostCommon != null) {
        final parts = mostCommon!.split('_');
        final x = int.parse(parts[0]);
        final y = int.parse(parts[1]);

        final xorKey = x ^ 0xFF;
        final check = y ^ 0xD9;

        if (xorKey == check) {
          return xorKey;
        }
      }
    } catch (e) {
      return null;
    }

    return null;
  }

  static Future<Uint8List?> _getCiphertextFromTemplate(
    List<File> templateFiles,
  ) async {
    for (final file in templateFiles) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.length < 0x1F) {
          continue;
        }

        final header = bytes.sublist(0, 6);
        if (header[0] == 0x07 &&
            header[1] == 0x08 &&
            header[2] == 0x56 &&
            header[3] == 0x32 &&
            header[4] == 0x08 &&
            header[5] == 0x07) {
          return bytes.sublist(0xF, 0x1F);
        }
      } catch (e) {
        continue;
      }
    }
    return null;
  }

  static bool _verifyKey(Uint8List encrypted, Uint8List aesKey) {
    try {
      final key = aesKey.sublist(0, 16);
      final cipher = ECBBlockCipher(AESEngine());
      cipher.init(false, KeyParameter(key));

      final decrypted = Uint8List(encrypted.length);
      for (int i = 0; i < encrypted.length; i += 16) {
        cipher.processBlock(
          encrypted,
          i,
          decrypted,
          i,
        );
      }

      return decrypted.length >= 3 &&
          decrypted[0] == 0xFF &&
          decrypted[1] == 0xD8 &&
          decrypted[2] == 0xFF;
    } catch (e) {
      return false;
    }
  }

  static Future<String?> _getAesKeyFromMemory(
    int pid,
    Uint8List ciphertext,
    void Function(String message)? onProgress,
  ) async {
    final hProcess = OpenProcess(
      PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
      FALSE,
      pid,
    );
    if (hProcess == 0) {
      return null;
    }

    try {
      final mInfo = calloc<MEMORY_BASIC_INFORMATION>();
      final infoSize = sizeOf<MEMORY_BASIC_INFORMATION>();
      var address = 0;
      var scannedRegions = 0;

      while (VirtualQueryEx(
            hProcess,
            Pointer.fromAddress(address),
            mInfo,
            infoSize,
          ) !=
          0) {
        final protect = mInfo.ref.Protect;
        final state = mInfo.ref.State;

        if (state == MEM_COMMIT &&
            (protect == PAGE_READWRITE || protect == PAGE_READONLY)) {
          final regionSize = mInfo.ref.RegionSize;
          final data = await _readMemory(
            hProcess,
            mInfo.ref.BaseAddress.address,
            regionSize,
          );

          if (data != null) {
            final key = _searchKeyInData(data, ciphertext);
            if (key != null) {
              return key;
            }
          }

          scannedRegions++;
          if (scannedRegions % 120 == 0) {
            onProgress?.call('正在扫描内存区域: $scannedRegions');
          }
        }

        address = mInfo.ref.BaseAddress.address + mInfo.ref.RegionSize;
      }
    } finally {
      CloseHandle(hProcess);
    }

    return null;
  }

  static String? _searchKeyInData(Uint8List data, Uint8List ciphertext) {
    try {
      final dataToScan =
          data.length > 10 * 1024 * 1024 ? data.sublist(0, 10 * 1024 * 1024) : data;

      for (int i = 0; i < dataToScan.length - 32; i++) {
        final candidate = dataToScan[i];
        if (candidate < 48 || candidate > 122) continue;

        if (!_isUtf16AsciiKey(dataToScan, i) &&
            !_isAsciiKey(dataToScan, i)) {
          continue;
        }

        if (_isAsciiKey(dataToScan, i)) {
          final keyBytes = dataToScan.sublist(i, i + 32);
          if (_verifyKey(ciphertext, keyBytes)) {
            return String.fromCharCodes(keyBytes);
          }
        } else {
          final keyBytes = Uint8List(32);
          for (int j = 0; j < 32; j++) {
            keyBytes[j] = dataToScan[i + (j * 2)];
          }
          if (_verifyKey(ciphertext, keyBytes)) {
            return String.fromCharCodes(keyBytes);
          }
        }
      }
    } catch (e) {
      return null;
    }

    return null;
  }

  static bool _isAsciiKey(Uint8List data, int start) {
    try {
      for (int i = 0; i < 32; i++) {
        final b = data[start + i];
        if ((b < 48 || b > 122) || (b > 57 && b < 65) || (b > 90 && b < 97)) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  static bool _isUtf16AsciiKey(Uint8List data, int start) {
    try {
      for (int i = 0; i < 32; i++) {
        final ascii = data[start + (i * 2)];
        final zero = data[start + (i * 2) + 1];
        if (zero != 0) return false;
        if ((ascii < 48 || ascii > 122) ||
            (ascii > 57 && ascii < 65) ||
            (ascii > 90 && ascii < 97)) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  static Future<Uint8List?> _readMemory(
    int hProcess,
    int address,
    int size,
  ) async {
    try {
      final buffer = calloc<Uint8>(size);
      final bytesRead = calloc<SIZE_T>();

      try {
        final result = ReadProcessMemory(
          hProcess,
          Pointer.fromAddress(address),
          buffer,
          size,
          bytesRead,
        );

        final readCount = result != 0 ? bytesRead.value : 0;
        if (result == 0 || readCount == 0) {
          return null;
        }

        return Uint8List.fromList(buffer.asTypedList(readCount));
      } finally {
        free(buffer);
        free(bytesRead);
      }
    } catch (e) {
      await WxKeyLogger.error('读取进程内存失败: $e');
      return null;
    }
  }

  static Future<String?> selectWeChatCacheDirectory() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '请选择微信账号目录（与微信-设置-账号与存储-存储位置一致）',
      );

      return selectedDirectory;
    } catch (e) {
      return null;
    }
  }

  static Future<ImageKeyResult> getImageKeys({
    String? manualDirectory,
    String? rootPath,
    String? preferredWxid,
    void Function(String message)? onProgress,
  }) async {
    try {
      await WxKeyLogger.info('开始获取图片密钥');
      onProgress?.call('正在定位微信缓存目录...');

      String? cacheDir;

      if (manualDirectory != null && manualDirectory.isNotEmpty) {
        cacheDir = manualDirectory;
      } else {
        cacheDir = await getWeChatCacheDirectory(
          rootPath: rootPath,
          preferredWxid: preferredWxid,
        );
      }

      if (cacheDir == null) {
        await WxKeyLogger.error('未找到微信缓存目录');
        return ImageKeyResult.failure(
          '未找到微信缓存目录，请手动选择目录',
          needManualSelection: true,
        );
      }
      await WxKeyLogger.info('找到缓存目录: $cacheDir');
      onProgress?.call('正在收集模板文件...');

      final templateFiles = await _findTemplateDatFiles(cacheDir);
      if (templateFiles.isEmpty) {
        await WxKeyLogger.error('未找到模板文件');
        return ImageKeyResult.failure('未找到模板文件，可能该微信账号没有图片缓存');
      }
      await WxKeyLogger.info('找到 ${templateFiles.length} 个模板文件');
      onProgress?.call('找到 ${templateFiles.length} 个模板文件，正在计算XOR密钥...');

      final xorKey = await _getXorKey(templateFiles);
      if (xorKey == null) {
        await WxKeyLogger.error('无法获取XOR密钥');
        return ImageKeyResult.failure('无法获取XOR密钥');
      }
      await WxKeyLogger.info(
        '成功获取XOR密钥: ${xorKey.toRadixString(16).padLeft(2, '0')}',
      );
      onProgress?.call('XOR密钥获取成功，正在读取加密数据...');

      final ciphertext = await _getCiphertextFromTemplate(templateFiles);
      if (ciphertext == null) {
        await WxKeyLogger.error('无法读取加密数据');
        return ImageKeyResult.failure('无法读取加密数据');
      }
      await WxKeyLogger.info('成功读取 ${ciphertext.length} 字节加密数据');
      onProgress?.call('成功读取加密数据，正在检查微信进程...');

      final pids = DllInjector.findProcessIds('Weixin.exe');
      if (pids.isEmpty) {
        await WxKeyLogger.error('微信进程未运行');
        return ImageKeyResult.failure('微信进程未运行');
      }
      await WxKeyLogger.info('找到微信进程 PID: ${pids.first}');
      onProgress?.call('已定位微信进程，正在扫描内存获取AES密钥...');

      await WxKeyLogger.info('开始从内存中搜索AES密钥');
      final aesKey = await _getAesKeyFromMemory(
        pids.first,
        ciphertext,
        onProgress,
      ).timeout(const Duration(seconds: 45), onTimeout: () async {
        await WxKeyLogger.error('内存搜索超时，可能被系统权限或安全软件阻止');
        return null;
      });
      if (aesKey == null) {
        await WxKeyLogger.error('无法从内存中获取AES密钥');
        return ImageKeyResult.failure(
          '无法从内存中获取AES密钥。\n'
          '建议操作步骤：\n'
          '1. 彻底关闭当前登录的微信。\n'
          '2. 重新启动微信并登录。\n'
          '3. 打开朋友圈，寻找带图片的动态。\n'
          '4. 点击图片，再点击右上角打开大图。\n'
          '5. 重复步骤3和4，大概2-3次即可。\n'
          '6. 迅速回到工具内获取图片密钥。',
        );
      }
      await WxKeyLogger.success('成功获取AES密钥: ${aesKey.substring(0, 16)}');

      await WxKeyLogger.success('图片密钥获取完成');
      return ImageKeyResult.success(xorKey, aesKey.substring(0, 16));
    } catch (e, stackTrace) {
      await WxKeyLogger.error('获取密钥失败', e, stackTrace);
      return ImageKeyResult.failure('获取密钥失败: $e');
    }
  }
}
