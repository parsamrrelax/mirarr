import 'dart:convert';
import 'dart:ui';

import 'package:Mirarr/functions/fetchers/fetch_serie_details.dart';
import 'package:Mirarr/functions/get_base_url.dart';
import 'package:Mirarr/functions/regionprovider_class.dart';
import 'package:Mirarr/moviesPage/functions/on_tap_gridview_movie.dart';
import 'package:Mirarr/seriesPage/function/on_tap_gridview_serie.dart';
import 'package:Mirarr/widgets/rss_screen.dart';
import 'package:Mirarr/widgets/settings_screen.dart';
import 'package:Mirarr/widgets/watchlist_calendar_screen.dart';
import 'package:Mirarr/utils/expressive_motion.dart';
import 'package:Mirarr/widgets/expressive_interactive_container.dart';
import 'package:Mirarr/widgets/expressive_page_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive/hive.dart';
import 'package:Mirarr/moviesPage/UI/customMovieWidget.dart';
import 'package:Mirarr/seriesPage/UI/customSeriesWidget.dart';
import 'package:Mirarr/seriesPage/models/serie.dart';
import 'package:Mirarr/services/api_client.dart';
import 'package:Mirarr/moviesPage/models/movie.dart';
import 'package:provider/provider.dart';
import 'package:Mirarr/moviesPage/movieDetailPage.dart';
import 'package:Mirarr/seriesPage/serieDetailPage.dart';
import 'package:Mirarr/functions/navigation_provider.dart';
import 'package:Mirarr/widgets/bottom_bar.dart';
import 'package:Mirarr/widgets/tv_focus_wrapper.dart';


class ProfilePage extends StatefulWidget {
  ProfilePage({Key? key}) : super(key: key);

  @override
  _ProfilePageState createState() => _ProfilePageState();
}

List<Serie> tvWatchList = [];
List<Movie> moviesWatchList = [];
List<Serie> tvFavorites = [];
List<Movie> movieFavorites = [];
List<Serie> tvRated = [];
List<Movie> movieRated = [];
List<Serie> recentEpisodes = [];

final ValueNotifier<int> profileRefreshNotifier = ValueNotifier<int>(0);

/// App-lifetime cache of last-air metadata keyed by TMDB serie id.
final Map<int, Map<String, dynamic>> _serieAirCache = {};

class _ProfilePageState extends State<ProfilePage> {
  final apiKey = dotenv.env['TMDB_API_KEY'];
  int _lastIndex = -1;
  late final NavigationProvider _nav;
  DateTime? _lastSuccessfulFetch;
  static const _profileStaleDuration = Duration(seconds: 60);
  static const _detailConcurrency = 8;
  static const _pageConcurrency = 4;

  Map<String, dynamic>? _accountDetails;

  int _movieWatchListFetchId = 0;
  int _tvWatchListFetchId = 0;
  int _movieFavoritesFetchId = 0;
  int _tvFavoritesFetchId = 0;
  int _movieRatedFetchId = 0;
  int _tvRatedFetchId = 0;

  Future<void> _navigateToMovie(String title, int id) async {
    await Navigator.push(
      context,
      ExpressivePageRoute(
        page: MovieDetailPage(movieTitle: title, movieId: id),
      ),
    );
    checkInternetAndFetchData();
  }

  Future<void> _navigateToSerie(String title, int id) async {
    await Navigator.push(
      context,
      ExpressivePageRoute(
        page: SerieDetailPage(serieName: title, serieId: id),
      ),
    );
    checkInternetAndFetchData();
  }

  void _logout(BuildContext context) async {
    final box = Hive.box('sessionBox');
    await box.delete('sessionData');
  }

  @override
  void initState() {
    super.initState();
    _nav = context.read<NavigationProvider>()..addListener(_onNavChanged);
    _lastIndex = _nav.currentIndex;
    checkInternetAndFetchData();
    profileRefreshNotifier.addListener(_onProfileRefreshRequest);
  }

  void _onNavChanged() {
    if (_nav.currentIndex == 4 && _lastIndex != 4) {
      checkInternetAndFetchData();
    }
    _lastIndex = _nav.currentIndex;
  }

  @override
  void dispose() {
    _nav.removeListener(_onNavChanged);
    profileRefreshNotifier.removeListener(_onProfileRefreshRequest);
    super.dispose();
  }

  void _onProfileRefreshRequest() {
    if (mounted) {
      checkInternetAndFetchData(force: true);
    }
  }

  Future<void> fetchMovieWatchList(BuildContext context) async {
    final openbox = Hive.box('sessionBox');
    final String accountId = openbox.get('accountId');
    final String sessionData = openbox.get('sessionData');
    final region =
        Provider.of<RegionProvider>(context, listen: false).currentRegion;
    final baseUrl = getBaseUrl(region);

    final currentFetchId = ++_movieWatchListFetchId;

    final response = await apiClient.get(
      Uri.parse(
        '${baseUrl}account/$accountId/watchlist/movies?api_key=$apiKey&session_id=$sessionData&page=1',
      ),
    );

    if (response.statusCode == 200) {
      if (currentFetchId != _movieWatchListFetchId) return;
      final Map<String, dynamic> decoded = json.decode(response.body);
      final List<Movie> movies = [];
      final List<dynamic> results = decoded['results'] ?? [];

      for (var result in results) {
        final movie = Movie(
            title: result['title'],
            releaseDate: result['release_date'],
            posterPath: result['poster_path'] ?? '',
            overView: result['overview'] ?? '',
            id: result['id'] ?? '',
            score: result['vote_average'] ?? '');
        movies.add(movie);
      }

      setState(() {
        moviesWatchList = movies;
      });

      final int totalPages = decoded['total_pages'] ?? 1;
      if (totalPages > 1) {
        _fetchRemainingMovieWatchList(currentFetchId, totalPages, baseUrl, accountId, sessionData);
      }
    } else {
      throw Exception('Failed to load popular movie data');
    }
  }

  void _fetchRemainingMovieWatchList(int fetchId, int totalPages, String baseUrl, String accountId, String sessionData) async {
    final extra = await _fetchRemainingMoviePages(
      totalPages: totalPages,
      urlForPage: (page) =>
          '${baseUrl}account/$accountId/watchlist/movies?api_key=$apiKey&session_id=$sessionData&page=$page',
      isCurrent: () => fetchId == _movieWatchListFetchId,
    );
    if (extra.isEmpty || fetchId != _movieWatchListFetchId || !mounted) return;
    setState(() {
      moviesWatchList.addAll(extra);
    });
  }

  Future<List<Movie>> _fetchRemainingMoviePages({
    required int totalPages,
    required String Function(int page) urlForPage,
    required bool Function() isCurrent,
  }) async {
    final extra = <Movie>[];
    for (var start = 2; start <= totalPages; start += _pageConcurrency) {
      if (!isCurrent() || !mounted) return extra;
      final end = start + _pageConcurrency - 1 > totalPages
          ? totalPages
          : start + _pageConcurrency - 1;
      final pages = List.generate(end - start + 1, (i) => start + i);
      final pageResults = await Future.wait(pages.map((page) async {
        try {
          final response = await apiClient.get(Uri.parse(urlForPage(page)));
          if (response.statusCode != 200) return <Movie>[];
          final results = json.decode(response.body)['results'] as List<dynamic>? ?? [];
          return results
              .map((result) => Movie(
                    title: result['title'],
                    releaseDate: result['release_date'],
                    posterPath: result['poster_path'] ?? '',
                    overView: result['overview'] ?? '',
                    id: result['id'] ?? '',
                    score: result['vote_average'] ?? '',
                  ))
              .toList();
        } catch (_) {
          return <Movie>[];
        }
      }));
      for (final pageMovies in pageResults) {
        extra.addAll(pageMovies);
      }
    }
    return extra;
  }

  Future<void> fetchFavoriteMovies(BuildContext context) async {
    final openbox = Hive.box('sessionBox');
    final String accountId = openbox.get('accountId');
    final String sessionData = openbox.get('sessionData');
    final region =
        Provider.of<RegionProvider>(context, listen: false).currentRegion;
    final baseUrl = getBaseUrl(region);

    final currentFetchId = ++_movieFavoritesFetchId;

    final response = await apiClient.get(
      Uri.parse(
        '${baseUrl}account/$accountId/favorite/movies?api_key=$apiKey&session_id=$sessionData&page=1',
      ),
    );

    if (response.statusCode == 200) {
      if (currentFetchId != _movieFavoritesFetchId) return;
      final Map<String, dynamic> decoded = json.decode(response.body);
      final List<Movie> movies = [];
      final List<dynamic> results = decoded['results'] ?? [];

      for (var result in results) {
        final movie = Movie(
            title: result['title'],
            releaseDate: result['release_date'],
            posterPath: result['poster_path'] ?? '',
            overView: result['overview'] ?? '',
            id: result['id'] ?? '',
            score: result['vote_average'] ?? '');
        movies.add(movie);
      }

      setState(() {
        movieFavorites = movies;
      });

      final int totalPages = decoded['total_pages'] ?? 1;
      if (totalPages > 1) {
        _fetchRemainingFavoriteMovies(currentFetchId, totalPages, baseUrl, accountId, sessionData);
      }
    } else {
      throw Exception('Failed to load popular movie data');
    }
  }

  void _fetchRemainingFavoriteMovies(int fetchId, int totalPages, String baseUrl, String accountId, String sessionData) async {
    final extra = await _fetchRemainingMoviePages(
      totalPages: totalPages,
      urlForPage: (page) =>
          '${baseUrl}account/$accountId/favorite/movies?api_key=$apiKey&session_id=$sessionData&page=$page',
      isCurrent: () => fetchId == _movieFavoritesFetchId,
    );
    if (extra.isEmpty || fetchId != _movieFavoritesFetchId || !mounted) return;
    setState(() {
      movieFavorites.addAll(extra);
    });
  }

  Future<void> fetchRatedMovies(BuildContext context) async {
    final openbox = Hive.box('sessionBox');
    final String accountId = openbox.get('accountId');
    final String sessionData = openbox.get('sessionData');
    final region =
        Provider.of<RegionProvider>(context, listen: false).currentRegion;
    final baseUrl = getBaseUrl(region);

    final currentFetchId = ++_movieRatedFetchId;

    final response = await apiClient.get(
      Uri.parse(
        '${baseUrl}account/$accountId/rated/movies?api_key=$apiKey&session_id=$sessionData&page=1',
      ),
    );

    if (response.statusCode == 200) {
      if (currentFetchId != _movieRatedFetchId) return;
      final Map<String, dynamic> decoded = json.decode(response.body);
      final List<Movie> movies = [];
      final List<dynamic> results = decoded['results'] ?? [];

      for (var result in results) {
        final movie = Movie(
            title: result['title'],
            releaseDate: result['release_date'],
            posterPath: result['poster_path'] ?? '',
            overView: result['overview'] ?? '',
            id: result['id'] ?? '',
            score: result['vote_average'] ?? '');
        movies.add(movie);
      }

      setState(() {
        movieRated = movies;
      });

      final int totalPages = decoded['total_pages'] ?? 1;
      if (totalPages > 1) {
        _fetchRemainingRatedMovies(currentFetchId, totalPages, baseUrl, accountId, sessionData);
      }
    } else {
      throw Exception('Failed to load popular movie data');
    }
  }

  void _fetchRemainingRatedMovies(int fetchId, int totalPages, String baseUrl, String accountId, String sessionData) async {
    final extra = await _fetchRemainingMoviePages(
      totalPages: totalPages,
      urlForPage: (page) =>
          '${baseUrl}account/$accountId/rated/movies?api_key=$apiKey&session_id=$sessionData&page=$page',
      isCurrent: () => fetchId == _movieRatedFetchId,
    );
    if (extra.isEmpty || fetchId != _movieRatedFetchId || !mounted) return;
    setState(() {
      movieRated.addAll(extra);
    });
  }

  Future<void> fetchAccountInfo() async {
    if (!mounted) return;

    try {
      final openbox = Hive.box('sessionBox');
      final String? sessionData = openbox.get('sessionData');
      if (sessionData == null) return;
      final region = Provider.of<RegionProvider>(context, listen: false).currentRegion;
      final baseUrl = getBaseUrl(region);

      final response = await apiClient.get(
        Uri.parse(
          '${baseUrl}account?api_key=$apiKey&session_id=$sessionData',
        ),
      );

      if (response.statusCode == 200) {
        if (!mounted) return;
        setState(() {
          _accountDetails = json.decode(response.body);
        });
      }
    } catch (e) {
      // Handle silently
    }
  }

  Future<void> checkInternetAndFetchData({bool force = false}) async {
    if (!force &&
        _lastSuccessfulFetch != null &&
        DateTime.now().difference(_lastSuccessfulFetch!) <
            _profileStaleDuration) {
      return;
    }
    _lastSuccessfulFetch = DateTime.now();
    fetchAccountInfo();
    fetchMovieWatchList(context);
    fetchTvWatchList(context);
    fetchFavoriteMovies(context);
    fetchRatedMovies(context);
    fetchFavoriteSeries(context);
    fetchRatedTv(context);
  }

  /// Fetch last-air fields for [series] with a concurrency pool and app-lifetime cache.
  Future<List<Map<String, dynamic>?>> _fetchSerieAirDetailsPooled(
    List<Serie> series,
    String region,
  ) async {
    final results = List<Map<String, dynamic>?>.filled(series.length, null);

    for (var i = 0; i < series.length; i += _detailConcurrency) {
      final end = (i + _detailConcurrency < series.length)
          ? i + _detailConcurrency
          : series.length;
      final chunkIndexes = List.generate(end - i, (k) => i + k);

      await Future.wait(chunkIndexes.map((idx) async {
        final serieId = series[idx].id;
        final cached = _serieAirCache[serieId];
        if (cached != null) {
          results[idx] = cached;
          return;
        }
        try {
          final details = await fetchSerieDetails(serieId, region);
          final entry = <String, dynamic>{
            'last_air_date': details['last_air_date'],
            'last_episode_to_air': details['last_episode_to_air'],
          };
          _serieAirCache[serieId] = entry;
          results[idx] = entry;
        } catch (_) {
          results[idx] = null;
        }
      }));
    }

    return results;
  }

  List<Serie> _recentEpisodesFromDetails(
    List<Serie> series,
    List<Map<String, dynamic>?> allSerieDetails,
    DateTime today,
  ) {
    final pageRecentEpisodes = <Serie>[];
    for (var i = 0; i < series.length; i++) {
      final serie = series[i];
      final serieDetails = allSerieDetails[i];
      if (serieDetails == null) continue;

      final serieLatestAir = serieDetails['last_air_date'];
      if (serieLatestAir == null) continue;

      final serieLastEpisodeSeasonNumber =
          serieDetails['last_episode_to_air']?['season_number'];
      final serieLastEpisodeEpisodeNumber =
          serieDetails['last_episode_to_air']?['episode_number'];
      final serieLatestAirDate = DateTime.parse(serieLatestAir);

      final difference = today.difference(serieLatestAirDate).inDays;
      if (difference <= 14) {
        pageRecentEpisodes.add(Serie(
          name: serie.name,
          posterPath: serie.posterPath,
          overView: serie.overView,
          id: serie.id,
          score: serie.score,
          lastAirDate: serieLatestAir,
          lastEpisodeSeasonNumber: serieLastEpisodeSeasonNumber,
          lastEpisodeEpisodeNumber: serieLastEpisodeEpisodeNumber,
        ));
      }
    }
    return pageRecentEpisodes;
  }

  Future<void> fetchTvWatchList(BuildContext context) async {
    final openbox = Hive.box('sessionBox');
    final String accountId = openbox.get('accountId');
    final String sessionData = openbox.get('sessionData');
    final region =
        Provider.of<RegionProvider>(context, listen: false).currentRegion;
    final baseUrl = getBaseUrl(region);

    final currentFetchId = ++_tvWatchListFetchId;

    final response = await apiClient.get(
      Uri.parse(
        '${baseUrl}account/$accountId/watchlist/tv?api_key=$apiKey&session_id=$sessionData&page=1',
      ),
    );

    if (response.statusCode == 200) {
      if (currentFetchId != _tvWatchListFetchId) return;
      final Map<String, dynamic> decoded = json.decode(response.body);
      final List<Serie> series = [];
      final List<dynamic> results = decoded['results'] ?? [];
      recentEpisodes.clear();

      for (var result in results) {
        final serie = Serie(
            name: result['name'],
            posterPath: result['poster_path'] ?? '',
            overView: result['overview'] ?? '',
            id: result['id'],
            score: result['vote_average'] ?? '');
        series.add(serie);
      }

      setState(() {
        tvWatchList = series;
      });

      final today = DateTime.now();
      final allSerieDetails =
          await _fetchSerieAirDetailsPooled(series, region);

      if (currentFetchId != _tvWatchListFetchId) return;

      final pageRecentEpisodes =
          _recentEpisodesFromDetails(series, allSerieDetails, today);

      // Sort recentEpisodes by lastAirDate in descending order (newest first)
      pageRecentEpisodes.sort((a, b) => DateTime.parse(b.lastAirDate!).compareTo(DateTime.parse(a.lastAirDate!)));
      setState(() {
        recentEpisodes = pageRecentEpisodes;
      });

      final int totalPages = decoded['total_pages'] ?? 1;
      if (totalPages > 1) {
        _fetchRemainingTvWatchList(currentFetchId, totalPages, baseUrl, accountId, sessionData, region);
      }
    } else {
      throw Exception('Failed to load trending series data');
    }
  }

  Future<List<Serie>> _fetchRemainingSeriePages({
    required int totalPages,
    required String Function(int page) urlForPage,
    required bool Function() isCurrent,
  }) async {
    final extra = <Serie>[];
    for (var start = 2; start <= totalPages; start += _pageConcurrency) {
      if (!isCurrent() || !mounted) return extra;
      final end = start + _pageConcurrency - 1 > totalPages
          ? totalPages
          : start + _pageConcurrency - 1;
      final pages = List.generate(end - start + 1, (i) => start + i);
      final pageResults = await Future.wait(pages.map((page) async {
        try {
          final response = await apiClient.get(Uri.parse(urlForPage(page)));
          if (response.statusCode != 200) return <Serie>[];
          final results = json.decode(response.body)['results'] as List<dynamic>? ?? [];
          return results
              .map((result) => Serie(
                    name: result['name'],
                    posterPath: result['poster_path'] ?? '',
                    overView: result['overview'] ?? '',
                    id: result['id'],
                    score: result['vote_average'] ?? '',
                  ))
              .toList();
        } catch (_) {
          return <Serie>[];
        }
      }));
      for (final pageSeries in pageResults) {
        extra.addAll(pageSeries);
      }
    }
    return extra;
  }

  void _fetchRemainingTvWatchList(int fetchId, int totalPages, String baseUrl, String accountId, String sessionData, String region) async {
    final today = DateTime.now();
    final extra = await _fetchRemainingSeriePages(
      totalPages: totalPages,
      urlForPage: (page) =>
          '${baseUrl}account/$accountId/watchlist/tv?api_key=$apiKey&session_id=$sessionData&page=$page',
      isCurrent: () => fetchId == _tvWatchListFetchId,
    );
    if (extra.isEmpty || fetchId != _tvWatchListFetchId || !mounted) return;

    setState(() {
      tvWatchList.addAll(extra);
    });

    final allSerieDetails = await _fetchSerieAirDetailsPooled(extra, region);
    if (fetchId != _tvWatchListFetchId || !mounted) return;

    final newRecentEpisodes =
        _recentEpisodesFromDetails(extra, allSerieDetails, today);
    if (newRecentEpisodes.isEmpty) return;

    final updatedRecentEpisodes = List<Serie>.from(recentEpisodes)
      ..addAll(newRecentEpisodes);
    updatedRecentEpisodes.sort((a, b) =>
        DateTime.parse(b.lastAirDate!).compareTo(DateTime.parse(a.lastAirDate!)));
    setState(() {
      recentEpisodes = updatedRecentEpisodes;
    });
  }

  Future<void> fetchFavoriteSeries(BuildContext context) async {
    final openbox = Hive.box('sessionBox');
    final String accountId = openbox.get('accountId');
    final String sessionData = openbox.get('sessionData');
    final region =
        Provider.of<RegionProvider>(context, listen: false).currentRegion;
    final baseUrl = getBaseUrl(region);

    final currentFetchId = ++_tvFavoritesFetchId;

    final response = await apiClient.get(
      Uri.parse(
        '${baseUrl}account/$accountId/favorite/tv?api_key=$apiKey&session_id=$sessionData&page=1',
      ),
    );

    if (response.statusCode == 200) {
      if (currentFetchId != _tvFavoritesFetchId) return;
      final Map<String, dynamic> decoded = json.decode(response.body);
      final List<Serie> series = [];
      final List<dynamic> results = decoded['results'] ?? [];

      for (var result in results) {
        final serie = Serie(
            name: result['name'],
            posterPath: result['poster_path'] ?? '',
            overView: result['overview'] ?? '',
            id: result['id'],
            score: result['vote_average'] ?? '');
        series.add(serie);
      }

      setState(() {
        tvFavorites = series;
      });

      final int totalPages = decoded['total_pages'] ?? 1;
      if (totalPages > 1) {
        _fetchRemainingFavoriteSeries(currentFetchId, totalPages, baseUrl, accountId, sessionData);
      }
    } else {
      throw Exception('Failed to load trending series data');
    }
  }

  void _fetchRemainingFavoriteSeries(int fetchId, int totalPages, String baseUrl, String accountId, String sessionData) async {
    final extra = await _fetchRemainingSeriePages(
      totalPages: totalPages,
      urlForPage: (page) =>
          '${baseUrl}account/$accountId/favorite/tv?api_key=$apiKey&session_id=$sessionData&page=$page',
      isCurrent: () => fetchId == _tvFavoritesFetchId,
    );
    if (extra.isEmpty || fetchId != _tvFavoritesFetchId || !mounted) return;
    setState(() {
      tvFavorites.addAll(extra);
    });
  }

  Future<void> fetchRatedTv(BuildContext context) async {
    final openbox = Hive.box('sessionBox');
    final String accountId = openbox.get('accountId');
    final String sessionData = openbox.get('sessionData');
    final region =
        Provider.of<RegionProvider>(context, listen: false).currentRegion;
    final baseUrl = getBaseUrl(region);

    final currentFetchId = ++_tvRatedFetchId;

    final response = await apiClient.get(
      Uri.parse(
        '${baseUrl}account/$accountId/rated/tv?api_key=$apiKey&session_id=$sessionData&page=1',
      ),
    );

    if (response.statusCode == 200) {
      if (currentFetchId != _tvRatedFetchId) return;
      final Map<String, dynamic> decoded = json.decode(response.body);
      final List<Serie> series = [];
      final List<dynamic> results = decoded['results'] ?? [];

      for (var result in results) {
        final serie = Serie(
            name: result['name'],
            posterPath: result['poster_path'] ?? '',
            overView: result['overview'] ?? '',
            id: result['id'],
            score: result['vote_average'] ?? '');
        series.add(serie);
      }

      setState(() {
        tvRated = series;
      });

      final int totalPages = decoded['total_pages'] ?? 1;
      if (totalPages > 1) {
        _fetchRemainingRatedTv(currentFetchId, totalPages, baseUrl, accountId, sessionData);
      }
    } else {
      throw Exception('Failed to load trending series data');
    }
  }

  void _fetchRemainingRatedTv(int fetchId, int totalPages, String baseUrl, String accountId, String sessionData) async {
    final extra = await _fetchRemainingSeriePages(
      totalPages: totalPages,
      urlForPage: (page) =>
          '${baseUrl}account/$accountId/rated/tv?api_key=$apiKey&session_id=$sessionData&page=$page',
      isCurrent: () => fetchId == _tvRatedFetchId,
    );
    if (extra.isEmpty || fetchId != _tvRatedFetchId || !mounted) return;
    setState(() {
      tvRated.addAll(extra);
    });
  }


  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        final colorScheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;

        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          icon: Icon(Icons.logout_rounded, color: colorScheme.error, size: 32),
          title: Text(
            'Logout',
            style: textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
          content: Text(
            'Are you sure you want to logout from your account?',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          actions: <Widget>[
            OutlinedButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.onSurface,
                side: BorderSide(color: colorScheme.outlineVariant),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                _logout(context);
              },
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.error,
                foregroundColor: colorScheme.onError,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: const Text('Logout'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Expanded(
      child: ExpressiveInteractiveContainer(
        onTap: onTap,
        borderRadius: 20,
        pressedBorderRadius: 26,
        speed: ExpressiveSpeed.fast,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (iconColor ?? colorScheme.primary).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: iconColor ?? colorScheme.primary,
                size: 22,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileHeader() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final String username = _accountDetails?['username'] ?? 'Mirarr User';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      decoration: BoxDecoration(
        color: colorScheme.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: colorScheme.primaryContainer,
                child: Icon(Icons.person_rounded, color: colorScheme.onPrimaryContainer, size: 26),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome back',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    username,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildActionTile(
                icon: Icons.calendar_month_outlined,
                label: 'Calendar',
                onTap: () {
                  Navigator.push(
                    context,
                    ExpressivePageRoute(page: const WatchlistCalendarScreen()),
                  );
                },
              ),
              const SizedBox(width: 8),
              _buildActionTile(
                icon: Icons.rss_feed_rounded,
                label: 'RSS Feed',
                onTap: () {
                  Navigator.push(
                    context,
                    ExpressivePageRoute(page: const RssScreen()),
                  );
                },
              ),
              const SizedBox(width: 8),
              _buildActionTile(
                icon: Icons.settings_outlined,
                label: 'Settings',
                onTap: () {
                  Navigator.push(
                    context,
                    ExpressivePageRoute(page: const SettingsPage()),
                  );
                },
              ),
              const SizedBox(width: 8),
              _buildActionTile(
                icon: Icons.logout_rounded,
                label: 'Logout',
                iconColor: colorScheme.error,
                onTap: () {
                  _showLogoutDialog(context);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      extendBody: true,
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          'Profile',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
          },
        ),

          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            padding: EdgeInsets.only(
              bottom: TvFocusModeManager.isTvDevice ? 0.0 : BottomBar.getHeight(context),
            ),
            child: Column(
              children: [
                _buildProfileHeader(),
                Card(
                shadowColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    children: <Widget>[
                      Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(15, 15, 0, 5),
                            child: GestureDetector(
                              onTap: () =>
                                  onTapGridMovie(moviesWatchList, context),
                              child: Row(
                                children: [
                                  Text(
                                    textAlign: TextAlign.left,
                                    'Movie Watch List',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    color: colorScheme.primary,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      Visibility(
                        visible: moviesWatchList.isNotEmpty,
                        child: SizedBox(
                          height: 320, // Set the height for the movie cards
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.trackpad,
                              },
                            ),
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: moviesWatchList.length,
                              itemBuilder: (context, index) {
                                final movie = moviesWatchList[index];
                                return Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: GestureDetector(
                                    onTap: () => _navigateToMovie(movie.title, movie.id),
                                    child: CustomMovieWidget(
                                      movie: movie,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Visibility(
                        visible: moviesWatchList.isEmpty,
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(18.0),
                              child: Text(
                                'No movies in the watchlist yet',
                                style: TextStyle(
                                    color: colorScheme.primary,
                                    fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),    const SizedBox(
                        height: 10,
                      ),
                      Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(15, 15, 0, 5),
                            child: GestureDetector(
                              onTap: () => onTapGridSerie(recentEpisodes, context),
                              child: Row(
                                children: [
                                  Text(
                                    'Watchlist Recent Episodes',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    color: colorScheme.primary,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Visibility(
                        visible: recentEpisodes.isNotEmpty,
                        child: SizedBox(
                          height: 300, // Set the height for the movie cards
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.trackpad,
                              },
                            ),
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: recentEpisodes.length,
                              itemBuilder: (context, index) {

                                final serie = recentEpisodes[index];
                                return Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: GestureDetector(
                                    onTap: () => _navigateToSerie(serie.name, serie.id),
                                    child: Stack(
                                      children: [
                                        CustomSeriesWidget(
                                          serie: serie,
                                        ),
                                      Visibility(
                                        visible: serie.lastAirDate != null,
                                        child: Positioned(
                                          top: 50,
                                          left: 10,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.7),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              '${serie.lastAirDate}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),  Visibility(
                                        visible: serie.lastEpisodeSeasonNumber != null && serie.lastEpisodeEpisodeNumber != null,
                                        child: Positioned(
                                          top: 80,
                                          left: 10,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.7),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              'S${serie.lastEpisodeSeasonNumber}E${serie.lastEpisodeEpisodeNumber}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                              },
                            ),
                          ),
                        ),
                      ),
                      Visibility(
                        visible: recentEpisodes.isEmpty,
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(18.0),
                              child: Text(
                                'No series in your watchlist aired in the last 14 days',
                                style: TextStyle(
                                    color: colorScheme.primary,
                                    fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        height: 10,
                      ),
                      Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(15, 15, 0, 5),
                            child: GestureDetector(
                              onTap: () => onTapGridSerie(tvWatchList, context),
                              child: Row(
                                children: [
                                  Text(
                                    'TV Watch List',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    color: colorScheme.primary,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Visibility(
                        visible: tvWatchList.isNotEmpty,
                        child: SizedBox(
                          height: 300, // Set the height for the movie cards
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.trackpad,
                              },
                            ),
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: tvWatchList.length,
                              itemBuilder: (context, index) {
                                final serie = tvWatchList[index];
                                return Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: GestureDetector(
                                    onTap: () => _navigateToSerie(serie.name, serie.id),
                                    child: CustomSeriesWidget(
                                      serie: serie,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Visibility(
                        visible: tvWatchList.isEmpty,
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(18.0),
                              child: Text(
                                'No TV shows in the watchlist yet',
                                style: TextStyle(
                                    color: colorScheme.primary,
                                    fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(15, 15, 0, 5),
                            child: GestureDetector(
                              onTap: () =>
                                   onTapGridMovie(movieFavorites, context),
                              child: Row(
                                children: [
                                  Text(
                                    textAlign: TextAlign.left,
                                    'Favorite Movies',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    color: colorScheme.primary,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      Visibility(
                        visible: movieFavorites.isNotEmpty,
                        child: SizedBox(
                          height: 320,
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.trackpad,
                              },
                            ),
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: movieFavorites.length,
                              itemBuilder: (context, index) {
                                final movie = movieFavorites[index];
                                return Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: GestureDetector(
                                    onTap: () => _navigateToMovie(movie.title, movie.id),
                                    child: CustomMovieWidget(
                                      movie: movie,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Visibility(
                        visible: movieFavorites.isEmpty,
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(18.0),
                              child: Text(
                                'No favorite movies yet',
                                style: TextStyle(
                                    color: colorScheme.primary,
                                    fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        height: 10,
                      ),
                      Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(15, 15, 0, 5),
                            child: GestureDetector(
                              onTap: () => onTapGridSerie(tvFavorites, context),
                              child: Row(
                                children: [
                                  Text(
                                    'Favorite TV Shows',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    color: colorScheme.primary,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Visibility(
                        visible: tvFavorites.isNotEmpty,
                        child: SizedBox(
                          height: 300, // Set the height for the movie cards
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.trackpad,
                              },
                            ),
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: tvFavorites.length,
                              itemBuilder: (context, index) {
                                final serie = tvFavorites[index];
                                return Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: GestureDetector(
                                    onTap: () => _navigateToSerie(serie.name, serie.id),
                                    child: CustomSeriesWidget(
                                      serie: serie,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Visibility(
                        visible: tvFavorites.isEmpty,
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(18.0),
                              child: Text(
                                'No favorite TV shows yet',
                                style: TextStyle(
                                    color: colorScheme.primary,
                                    fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        height: 10,
                      ),
                      Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(15, 15, 0, 5),
                            child: GestureDetector(
                              onTap: () => onTapGridMovie(movieRated, context),
                              child: Row(
                                children: [
                                  Text(
                                    textAlign: TextAlign.left,
                                    'Rated Movies',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    color: colorScheme.primary,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      Visibility(
                        visible: movieRated.isNotEmpty,
                        child: SizedBox(
                          height: 320, // Set the height for the movie cards
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.trackpad,
                              },
                            ),
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: movieRated.length,
                              itemBuilder: (context, index) {
                                final movie = movieRated[index];
                                return Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: GestureDetector(
                                    onTap: () => _navigateToMovie(movie.title, movie.id),
                                    child: CustomMovieWidget(
                                      movie: movie,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Visibility(
                        visible: movieRated.isEmpty,
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(18.0),
                              child: Text(
                                'No rated movies yet',
                                style: TextStyle(
                                    color: colorScheme.primary,
                                    fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        height: 10,
                      ),
                      Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(15, 15, 0, 5),
                            child: GestureDetector(
                              onTap: () => onTapGridSerie(tvRated, context),
                              child: Row(
                                children: [
                                  Text(
                                    'Rated TV Shows',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    color: colorScheme.primary,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Visibility(
                        visible: tvRated.isNotEmpty,
                        child: SizedBox(
                          height: 300, // Set the height for the movie cards
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context).copyWith(
                              dragDevices: {
                                PointerDeviceKind.touch,
                                PointerDeviceKind.mouse,
                                PointerDeviceKind.trackpad,
                              },
                            ),
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: tvRated.length,
                              itemBuilder: (context, index) {
                                final serie = tvRated[index];
                                return Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: GestureDetector(
                                    onTap: () => _navigateToSerie(serie.name, serie.id),
                                    child: CustomSeriesWidget(
                                      serie: serie,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Visibility(
                        visible: tvRated.isEmpty,
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(18.0),
                              child: Text(
                                'No rated TV shows yet',
                                style: TextStyle(
                                    color: colorScheme.primary,
                                    fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ));
  }
}
