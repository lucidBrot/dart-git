import 'package:collection/collection.dart' show IterableExtension;
import 'package:file/file.dart';

import 'package:dart_git/dart_git.dart';
import 'package:dart_git/exceptions.dart';
import 'package:dart_git/plumbing/git_hash.dart';
import 'package:dart_git/plumbing/index.dart';
import 'package:dart_git/plumbing/objects/blob.dart';

extension Index on GitRepository {
  Result<void> add(String pathSpec) {
    final stopwatch = Stopwatch()..start();
    stopwatch.reset();

    pathSpec = normalizePath(pathSpec);

    var indexR = indexStorage.readIndex();
    if (indexR.isFailure) {
      return fail(indexR);
    }
    var index = indexR.getOrThrow();

    print("git-dart.add() 2 took ${stopwatch.elapsed}.");
    stopwatch.reset();

    var stat = fs.statSync(pathSpec);
    if (stat.type == FileSystemEntityType.file) {
      var result = addFileToIndex(index, pathSpec);
      print("git-dart.add() 3a took ${stopwatch.elapsed}.");
      stopwatch.reset();
      if (result.isFailure) {
        return fail(result);
      }
    } else if (stat.type == FileSystemEntityType.directory) {
      var result = addDirectoryToIndex(index, pathSpec, recursive: true);
      print("git-dart.add() 3b took ${stopwatch.elapsed}.");
      stopwatch.reset();
      if (result.isFailure) {
        return fail(result);
      }
    } else {
      var ex = InvalidFileType(pathSpec);
      return Result.fail(ex);
    }

    var result = indexStorage.writeIndex(index);
    print("git-dart.add() 4 took ${(stopwatch..stop()).elapsed}.");
    stopwatch.reset();
    return result;
  }

  Result<GitIndexEntry> addFileToIndex(
    GitIndex index,
    String filePath,
    {Stopwatch? stopwatch = null}
  ) {
    stopwatch ??= Stopwatch();

    filePath = normalizePath(filePath);

    var file = fs.file(filePath);
    if (!file.existsSync()) {
      var ex = GitFileNotFound(filePath);
      return Result.fail(ex);
    }

    var pathSpec = filePath;
    if (pathSpec.startsWith(workTree)) {
      pathSpec = filePath.substring(workTree.length);
    }
    // LB: Wait is this a linear search over all files??
    //     Maybe... but omitting it fully does not speed things up.
    var entry = index.entries.firstWhereOrNull((e) => e.path == pathSpec);
    var stat = FileStat.statSync(filePath);
    if (entry != null &&
        entry.cTime.isAtSameMomentAs(stat.changed) &&
        entry.mTime.isAtSameMomentAs(stat.modified) &&
        entry.fileSize == stat.size){
        // We assume it is the same file.
        print("dart-git.addFileToIndex(${filePath}) assumed unchanged.");
        return Result(entry);
    }
    print("dart-git.addFileToIndex(${filePath}) potentially modified.");
    if (false) { // just for debugging verbosity "logs"
      print("\tentry${entry == null ? " is null " : " is non-null"}.");
      if (entry != null) {
        print("FileSize ${entry.fileSize} -> ${stat.size}");
      }
      if (entry != null && entry.cTime != stat.changed) {
        print("\tEntry ctime was ${entry.cTime}, stat ctime was ${stat
            .changed}.");
      }
      if (entry != null && entry.mTime != stat.modified) {
        print("\tEntry ctime was ${entry.mTime}, stat mtime was ${stat
            .modified}.");
      }
    }

    // LB: Note that this reads and hashes the file, even if nothing changed.
    //     .. hence the check above using the ctime/mtime.
    // Save that file as a blob (takes ~0.3 seconds)
    var data = file.readAsBytesSync();
    stopwatch.start();
    // Hash the file (takes ~1.7 seconds)
    var blob = GitBlob(data, null);
    stopwatch.stop();
    var hashR = objStorage.writeObject(blob);
    if (hashR.isFailure) {
      return fail(hashR);
    }

    var hash = hashR.getOrThrow();

    // Add it to the index

    // Existing file
    if (entry != null) {
      entry.hash = hash;
      entry.fileSize = data.length;
      assert(data.length == stat.size);

      entry.cTime = stat.changed;
      entry.mTime = stat.modified;
      return Result(entry);
    }

    // New file
    entry = GitIndexEntry.fromFS(pathSpec, stat, hash);
    index.entries.add(entry);
    return Result(entry);
  }

  Result<void> addDirectoryToIndex(
    GitIndex index,
    String dirPath, {
    bool recursive = false,
  }) {
    /*
      This function takes 2 seconds.

     */

    dirPath = normalizePath(dirPath);

    var dir = fs.directory(dirPath);

    final stopwatch = Stopwatch();
    final inner_stopwatch = Stopwatch();

    for (var fsEntity
        in dir.listSync(recursive: recursive, followLinks: false)) {
      if (fsEntity.path.startsWith(gitDir)) {
        continue;
      }
      var stat = fsEntity.statSync();
      if (stat.type != FileSystemEntityType.file) {
        continue;
      }

      stopwatch.start();
      var r = addFileToIndex(index, fsEntity.path, stopwatch: inner_stopwatch);
      stopwatch.stop();
      if (r.isFailure) {
        return fail(r);
      }
    }
    print("dart-git#index.dart: addDirectoryToIndex() spent ${(stopwatch..stop()).elapsed} on adding non-skipped files");
    print("dart-git#index.dart: addDirectoryToIndex() Inner Stopwatch: ${(inner_stopwatch..stop()).elapsed} ");

    return Result(null);
  }

  Result<void> rm(String pathSpec, {bool rmFromFs = true}) {
    pathSpec = normalizePath(pathSpec);

    var indexR = indexStorage.readIndex();
    if (indexR.isFailure) {
      return fail(indexR);
    }
    var index = indexR.getOrThrow();

    var stat = fs.statSync(pathSpec);
    if (stat.type == FileSystemEntityType.file) {
      var r = rmFileFromIndex(index, pathSpec);
      if (r.isFailure) {
        return fail(r);
      }
      if (rmFromFs) {
        fs.file(pathSpec).deleteSync();
      }
    } else if (stat.type == FileSystemEntityType.directory) {
      var r = rmDirectoryFromIndex(index, pathSpec, recursive: true);
      if (r.isFailure) {
        return fail(r);
      }
      if (rmFromFs) {
        fs.directory(pathSpec).deleteSync(recursive: true);
      }
    } else {
      var ex = InvalidFileType(pathSpec);
      return Result.fail(ex);
    }

    return indexStorage.writeIndex(index);
  }

  Result<GitHash> rmFileFromIndex(
    GitIndex index,
    String filePath,
  ) {
    var pathSpec = toPathSpec(normalizePath(filePath));
    var hash = index.removePath(pathSpec);
    if (hash == null) {
      var ex = GitNotFound();
      return Result.fail(ex);
    }
    return Result(hash);
  }

  Result<void> rmDirectoryFromIndex(
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

      var r = rmFileFromIndex(index, fsEntity.path);
      if (r.isFailure) {
        return fail(r);
      }
    }

    return Result(null);
  }
}
