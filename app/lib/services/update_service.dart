// Fetching a published build, and handing it to Android to install.
//
// The decision about *whether* to offer an update is not here — it is in
// `core/app_update.dart`, so it can be tested without a network. This file is
// only the plumbing: read the manifest, download the APK, open it.
//
// WHERE THE FILES COME FROM
//
// `.github/workflows/android-apk.yml` builds a release-signed APK on every
// push that touches `app/`, and publishes it to a GitHub Release along with a
// small `version.json`. Both are read through the `releases/latest/download/`
// path, which always resolves to the newest release and is a plain file
// download — **not** the GitHub API. That matters: the API allows 60
// unauthenticated requests an hour per IP, and a dozen reps in one office
// share one. A file download has no such limit.
//
// The repository is public, so neither request carries a token. Nothing in the
// APK is secret; a rep still signs in to ERPNext.
//
// WHY IT IS ITS OWN Dio
//
// `Session.I.dio` is pointed at the ERPNext site and carries the session
// cookie and the error interceptors that go with it. GitHub is neither, and
// sending Frappe's cookie to another host would be wrong on its own.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'package:manna_field_sales/core/app_update.dart';
import 'package:manna_field_sales/core/app_version.dart';

class UpdateService {
  /// Where CI publishes. Fixed rather than derived: the app has to know one
  /// repository, and this is the one releases are cut from.
  static const String repo = 'Mannagoc/SALES_DASHBOARD';

  static const String _manifestUrl =
      'https://github.com/$repo/releases/latest/download/version.json';

  /// Short. This runs while a rep is opening the app, and an update is a
  /// convenience — it must never be the reason the home screen is slow.
  static final Dio _net = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 6),
    // GitHub answers 404 for a repo with no releases yet, which is an ordinary
    // state on the day this ships and must not throw.
    validateStatus: (s) => s != null && s < 500,
    responseType: ResponseType.plain,
  ));

  /// What is running, as Android reports it.
  ///
  /// Read from the installed package rather than from [kAppVersion], because
  /// the build number is what CI increments and no constant in the source
  /// tracks it. Falls back to the compiled-in version if the platform channel
  /// is unavailable, which is what happens in tests.
  static Future<({String version, int? build})> installed() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return (
        version: info.version.isEmpty ? kAppVersion : info.version,
        build: int.tryParse(info.buildNumber.trim()),
      );
    } catch (_) {
      return (version: kAppVersion, build: null);
    }
  }

  /// The update worth offering, or null.
  ///
  /// Never throws. Every failure — offline, 404, a proxy serving an HTML error
  /// page — is "no update": see `core/app_update.dart` for why this fails
  /// silent rather than telling a rep something they cannot act on.
  static Future<AvailableUpdate?> check() async {
    try {
      final r = await _net.get<String>(_manifestUrl);
      if (r.statusCode != 200) return null;

      final body = (r.data ?? '').trim();
      if (body.isEmpty) return null;

      // Guard the decode itself: `releases/latest/download/` on a repository
      // with no matching asset serves an HTML page, not JSON.
      final dynamic decoded;
      try {
        decoded = jsonDecode(body);
      } catch (_) {
        return null;
      }

      final me = await installed();
      return updateToOffer(
        manifest: decoded,
        currentVersion: me.version,
        currentBuild: me.build,
      );
    } catch (_) {
      return null;
    }
  }

  /// Download the APK, reporting 0..1 progress, and return where it landed.
  ///
  /// Written to the app's own cache directory. Nowhere else is writable
  /// without a storage permission the app does not ask for, and a file there
  /// is readable by the package installer through open_filex's provider.
  ///
  /// The previous download is deleted first. A part-written APK left by a
  /// dropped connection would otherwise be handed to the installer, which
  /// reports it as a corrupt package — an error that reads like a bad build
  /// rather than a bad download.
  static Future<File> download(
    AvailableUpdate update, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/manna-field-sales-${update.build ?? 0}.apk');
    if (await file.exists()) await file.delete();

    final part = File('${file.path}.part');
    if (await part.exists()) await part.delete();

    await _net.download(
      update.apkUrl,
      part.path,
      cancelToken: cancelToken,
      options: Options(
        // A release asset is tens of megabytes on a workshop's connection.
        receiveTimeout: const Duration(minutes: 10),
        // 200 and nothing else, overriding the instance's laxer rule. GitHub
        // answers a missing asset with an HTML page, and anything but a strict
        // check here would write that page out as the .apk — which reaches the
        // rep as "corrupt package", an error that reads like a bad build
        // rather than a failed download.
        validateStatus: (s) => s == 200,
      ),
      onReceiveProgress: (got, total) {
        if (total > 0 && onProgress != null) onProgress(got / total);
      },
    );

    // Only now is it a whole file. Renaming last is what makes a dropped
    // download impossible to mistake for a finished one.
    return part.rename(file.path);
  }

  /// Hand the file to Android's package installer.
  ///
  /// Returns an error message, or null when the installer opened. It cannot
  /// report whether the rep went through with it — that screen belongs to
  /// Android, and the app is usually killed when the install replaces it.
  ///
  /// The first time, Android asks the rep to allow "install unknown apps" for
  /// this app. That prompt is unavoidable for anything not coming from the
  /// Play Store, and it is asked once per device.
  static Future<String?> install(File apk) async {
    final r = await OpenFilex.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    if (r.type == ResultType.done) return null;
    return r.message.isEmpty
        ? 'Android would not open the installer.'
        : r.message;
  }
}
