import 'package:collection/collection.dart' show IterableExtension;
import 'package:file/file.dart';

import 'package:dart_git/dart_git.dart';
import 'package:dart_git/exceptions.dart';
import 'package:dart_git/plumbing/git_hash.dart';
import 'package:dart_git/plumbing/index.dart';
import 'package:dart_git/plumbing/objects/blob.dart';

extension Index on GitRepository {
  void add(String pathSpec) {
    pathSpec = normalizePath(pathSpec);

    var index = indexStorage.readIndex();

    var stat = fs.statSync(pathSpec);
    if (stat.type == FileSystemEntityType.file) {
      addFileToIndex(index, pathSpec);
    } else if (stat.type == FileSystemEntityType.directory) {
      addDirectoryToIndex(index, pathSpec, recursive: true);
    } else {
      throw InvalidFileType(pathSpec);
    }

    return indexStorage.writeIndex(index);
  }

  GitIndexEntry addFileToIndex(
    GitIndex index,
    String filePath,
  ) {
    filePath = normalizePath(filePath);

    var file = fs.file(filePath);
    if (!file.existsSync()) {
      throw GitFileNotFound(filePath);
    }

    // Save that file as a blob
    var data = file.readAsBytesSync();
    var blob = GitBlob(data, null);
    var hash = objStorage.writeObject(blob);

    var pathSpec = filePath;
    if (pathSpec.startsWith(workTree)) {
      pathSpec = filePath.substring(workTree.length);
    }

    // Add it to the index
    var entry = index.entries.firstWhereOrNull((e) => e.path == pathSpec);
    var stat = FileStat.statSync(filePath);

    // Existing file
    if (entry != null) {
      entry.hash = hash;
      entry.fileSize = data.length;
      assert(data.length == stat.size);

      entry.cTime = stat.changed;
      entry.mTime = stat.modified;
      return entry;
    }

    // New file
    entry = GitIndexEntry.fromFS(pathSpec, stat, hash);
    index.entries.add(entry);
    return entry;
  }

  void addDirectoryToIndex(
    GitIndex index,
    String dirPath, {
    bool recursive = false,
  }) {
    dirPath = normalizePath(dirPath);

    var dir = fs.directory(dirPath);
    for (var fsEntity
        in dir.listSync(recursive: recursive, followLinks: false)) {
      if (fsEntity.path.startsWith(gitDir)) {
        continue;
      }
      var stat = fsEntity.statSync();
      if (stat.type != FileSystemEntityType.file) {
        continue;
      }

      addFileToIndex(index, fsEntity.path);
    }

    return;
  }

  void rm(String pathSpec, {bool rmFromFs = true}) {
    pathSpec = normalizePath(pathSpec);

    var index = indexStorage.readIndex();

    var stat = fs.statSync(pathSpec);
    if (stat.type == FileSystemEntityType.file) {
      rmFileFromIndex(index, pathSpec);
      if (rmFromFs) {
        fs.file(pathSpec).deleteSync();
      }
    } else if (stat.type == FileSystemEntityType.directory) {
      rmDirectoryFromIndex(index, pathSpec, recursive: true);
      if (rmFromFs) {
        fs.directory(pathSpec).deleteSync(recursive: true);
      }
    } else {
      throw InvalidFileType(pathSpec);
    }

    return indexStorage.writeIndex(index);
  }

  GitHash rmFileFromIndex(
    GitIndex index,
    String filePath,
  ) {
    var pathSpec = toPathSpec(normalizePath(filePath));
    var hash = index.removePath(pathSpec);
    if (hash == null) {
      throw GitNotFound();
    }
    return hash;
  }

  void rmDirectoryFromIndex(
    GitIndex index,
    String dirPath, {
    bool recursive = false,
  }) {
    dirPath = normalizePath(dirPath);

    var dir = fs.directory(dirPath);
    for (var fsEntity in dir.listSync(
      recursive: recursive,
      followLinks: false,
    )) {
      if (fsEntity.path.startsWith(gitDir)) {
        continue;
      }
      var stat = fsEntity.statSync();
      if (stat.type != FileSystemEntityType.file) {
        continue;
      }

      rmFileFromIndex(index, fsEntity.path);
    }

    return;
  }
}
