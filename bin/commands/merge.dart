// ignore_for_file: avoid_print

import 'dart:io';

import 'package:args/command_runner.dart';

import 'package:dart_git/dart_git.dart';
import 'package:dart_git/utils/date_time.dart';

class MergeCommand extends Command<int> {
  @override
  final name = 'merge';

  @override
  final description = 'Join two or more development histories together';

  MergeCommand() {
    argParser.addOption('strategy-option', abbr: 'X');
    argParser.addOption('message', abbr: 'm');
  }

  @override
  int run() {
    var args = argResults!.rest;
    if (args.length != 1) {
      print('Incorrect usage');
      return 1;
    }

    var branchName = args[0];
    var gitRootDir = GitRepository.findRootDir(Directory.current.path)!;
    var repo = GitRepository.load(gitRootDir);
    var branchCommit = repo.branchCommit(branchName);
    if (branchCommit == null) {
      print('Branch $branchName not found');
      return 1;
    }

    var user = repo.config.user;
    if (user == null) {
      print('Git user not set. Fetching from env variables');
      user = GitAuthor(
        name: Platform.environment['GIT_AUTHOR_NAME']!,
        email: Platform.environment['GIT_AUTHOR_EMAIL']!,
      );
    }

    var authorDate = Platform.environment['GIT_AUTHOR_DATE'];
    if (authorDate != null) {
      user.date = GDateTime.parse(authorDate);
    }

    var committer = user;
    var comitterDate = Platform.environment['GIT_COMMITTER_DATE'];
    if (comitterDate != null) {
      committer.date = GDateTime.parse(comitterDate);
    }

    var msg = argResults!['message'] ?? "Merge branch '$branchName'\n";

    repo.merge(
      theirCommit: branchCommit,
      author: user,
      committer: committer,
      message: msg,
    );

    return 0;
  }
}
