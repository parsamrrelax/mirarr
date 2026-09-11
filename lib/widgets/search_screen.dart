import 'dart:convert';
import 'dart:async';
import 'dart:ui';
import 'package:Mirarr/functions/get_base_url.dart';
import 'package:Mirarr/functions/regionprovider_class.dart';
import 'package:Mirarr/moviesPage/UI/cast_crew_row.dart';
import 'package:Mirarr/moviesPage/UI/movie_result.dart';
import 'package:Mirarr/moviesPage/functions/on_tap_movie.dart';
import 'package:Mirarr/seriesPage/UI/serie_result.dart';
import 'package:Mirarr/seriesPage/function/on_tap_serie.dart';
import 'package:Mirarr/widgets/discover/discover_with_filters.dart';
import 'package:Mirarr/widgets/models/person.dart';
import 'package:Mirarr/widgets/person_result.dart';
import 'package:Mirarr/widgets/tv_focus_wrapper.dart';
import 'package:Mirarr/widgets/bottom_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:Mirarr/services/api_client.dart';
import 'package:Mirarr/moviesPage/models/movie.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:Mirarr/seriesPage/models/serie.dart';
import 'package:provider/provider.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({Key? key}) : super(key: key);

  @override
  _SearchScreenState createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  List<Movie> movieResults = [];
  List<Serie> tvResults = [];
  List<Person> personResults = [];

  final apiKey = dotenv.env['TMDB_API_KEY'];
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  int _searchFetchId = 0;

  late FocusNode _searchFocusNode;

  KeyEventResult _handleSearchFocusKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && TvFocusModeManager.isTvFocusMode.value) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        node.focusInDirection(TraversalDirection.down);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        node.focusInDirection(TraversalDirection.up);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _searchController.addListener(_onSearchChanged);
    _searchFocusNode = FocusNode(onKeyEvent: _handleSearchFocusKey);
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      final query = _searchController.text.trim();
      if (!mounted) return;
      if (query.isNotEmpty) {
        _runSearch(query);
      } else {
        _searchFetchId++;
        setState(() {
          movieResults = [];
          tvResults = [];
          personResults = [];
        });
      }
    });
  }

  Future<void> _runSearch(String query) async {
    final region =
        Provider.of<RegionProvider>(context, listen: false).currentRegion;
    final baseUrl = getBaseUrl(region);
    final encodedQuery = Uri.encodeQueryComponent(query);
    final currentFetchId = ++_searchFetchId;

    try {
      final results = await Future.wait([
        _fetchMovies(baseUrl, encodedQuery),
        _fetchSeries(baseUrl, encodedQuery),
        _fetchPeople(baseUrl, encodedQuery),
      ]);

      if (!mounted || currentFetchId != _searchFetchId) return;

      setState(() {
        movieResults = results[0] as List<Movie>;
        tvResults = results[1] as List<Serie>;
        personResults = results[2] as List<Person>;
      });
    } catch (e) {
      if (!mounted || currentFetchId != _searchFetchId) return;
      debugPrint('Search failed for "$query": $e');
    }
  }

  Future<List<Movie>> _fetchMovies(String baseUrl, String encodedQuery) async {
    final response = await apiClient.get(
      Uri.parse(
        '${baseUrl}search/movie?api_key=$apiKey&query=$encodedQuery',
      ),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to load movie data');
    }

    final List<Movie> movies = [];
    final List<dynamic> results = json.decode(response.body)['results'];
    for (var result in results) {
      movies.add(Movie(
        title: result['title'],
        releaseDate: result['release_date'] ?? '',
        posterPath: result['poster_path'] ?? '',
        overView: result['overview'] ?? '',
        id: result['id'] ?? '',
        backdropPath: result['backdrop_path'] ?? '',
        score: result['vote_average'] ?? 0.0,
      ));
    }
    return movies;
  }

  Future<List<Serie>> _fetchSeries(String baseUrl, String encodedQuery) async {
    final response = await apiClient.get(
      Uri.parse(
        '${baseUrl}search/tv?api_key=$apiKey&query=$encodedQuery',
      ),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to load serie data');
    }

    final List<Serie> series = [];
    final List<dynamic> results = json.decode(response.body)['results'];
    for (var result in results) {
      series.add(Serie(
        name: result['name'],
        posterPath: result['poster_path'] ?? '',
        overView: result['overview'] ?? '',
        id: result['id'],
        backdropPath: result['backdrop_path'] ?? '',
        score: result['vote_average'] ?? 0.0,
      ));
    }
    return series;
  }

  Future<List<Person>> _fetchPeople(String baseUrl, String encodedQuery) async {
    final response = await apiClient.get(
      Uri.parse(
        '${baseUrl}search/person?api_key=$apiKey&query=$encodedQuery',
      ),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to load people data');
    }

    final List<Person> persons = [];
    final List<dynamic> results = json.decode(response.body)['results'];
    for (var result in results) {
      persons.add(Person(
        name: result['name'],
        profilePath: result['profile_path'] ?? '',
        id: result['id'],
        department: result['known_for_department'] ?? '',
      ));
    }
    return persons;
  }

  String _getSearchLabelText(int tabIndex) {
    switch (tabIndex) {
      case 0:
        return 'Search for movies...';
      case 1:
        return 'Search for TV shows...';
      case 2:
        return 'Search for people...';
      default:
        return 'Search...';
    }
  }

  Widget _buildEmptyState(String message, IconData icon) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 64,
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoResultsState(String query) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 64,
            color: colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            "No results found for '$query'",
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMovieTab() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      return _buildEmptyState('Type to search for movies', Icons.movie_outlined);
    }
    if (movieResults.isEmpty) {
      return _buildNoResultsState(query);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width > 1200
            ? 5
            : width > 800
                ? 4
                : width > 600
                    ? 3
                    : 2;

        return ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(
            physics: const BouncingScrollPhysics(),
            scrollbars: true,
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            },
          ),
          child: GridView.builder(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 12,
              bottom: BottomBar.getHeight(context),
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.77,
            ),
            itemCount: movieResults.length,
            itemBuilder: (context, index) {
              final movie = movieResults[index];
              return TvFocusWrapper(
                borderRadius: 16.0,
                onTap: () => onTapMovie(movie.title, movie.id, context),
                child: MovieSearchResult(
                  movie: movie,
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTvTab() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      return _buildEmptyState('Type to search for TV shows', Icons.tv_outlined);
    }
    if (tvResults.isEmpty) {
      return _buildNoResultsState(query);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width > 1200
            ? 5
            : width > 800
                ? 4
                : width > 600
                    ? 3
                    : 2;

        return ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(
            physics: const BouncingScrollPhysics(),
            scrollbars: true,
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            },
          ),
          child: GridView.builder(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 12,
              bottom: BottomBar.getHeight(context),
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.77,
            ),
            itemCount: tvResults.length,
            itemBuilder: (context, index) {
              final serie = tvResults[index];
              return TvFocusWrapper(
                borderRadius: 16.0,
                onTap: () => onTapSerie(serie.name, serie.id, context),
                child: SerieSearchResult(
                  serie: serie,
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildPeopleTab() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      return _buildEmptyState('Type to search for people', Icons.people_outline);
    }
    if (personResults.isEmpty) {
      return _buildNoResultsState(query);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width > 1200
            ? 6
            : width > 800
                ? 4
                : width > 600
                    ? 3
                    : 2;

        return ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(
            physics: const BouncingScrollPhysics(),
            scrollbars: true,
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            },
          ),
          child: GridView.builder(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 12,
              bottom: BottomBar.getHeight(context),
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.7,
            ),
            itemCount: personResults.length,
            itemBuilder: (context, index) {
              final person = personResults[index];
              return TvFocusWrapper(
                borderRadius: 16.0,
                onTap: () => person.department == 'Acting'
                    ? onTapCast(context, person.id)
                    : onTapCrew(context, person.id),
                child: PersonSearchResult(
                  person: person,
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      extendBody: true,
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            // Hint + visibility depend on tab index; rebuild only this bar, not the grids.
            ValueListenableBuilder<double>(
              valueListenable: _tabController.animation!,
              builder: (context, animationValue, _) {
                final tabIndex = animationValue.round().clamp(0, 3);
                if (tabIndex == 3) return const SizedBox.shrink();

                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Align(
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: TextField(
                        focusNode: _searchFocusNode,
                        autocorrect: false,
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(color: colorScheme.onSurface),
                        cursorColor: colorScheme.primary,
                        controller: _searchController,
                        keyboardType: TextInputType.text,
                        decoration: InputDecoration(
                          hintText: _getSearchLabelText(tabIndex),
                          hintStyle: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6),
                          ),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          filled: true,
                          fillColor: colorScheme.surfaceContainerHigh,
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(
                                color: colorScheme.primary, width: 2),
                            borderRadius: BorderRadius.circular(28),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(
                              color: colorScheme.outlineVariant
                                  .withValues(alpha: 0.2),
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(28),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              vertical: 14, horizontal: 20),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: Icon(Icons.close_rounded,
                                      color: colorScheme.onSurfaceVariant),
                                  onPressed: () {
                                    _searchController.clear();
                                    _searchFetchId++;
                                    setState(() {
                                      movieResults = [];
                                      tvResults = [];
                                      personResults = [];
                                    });
                                  },
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

            // Material 3 Expressive Segmented TabBar
            LayoutBuilder(
              builder: (context, constraints) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      labelColor: colorScheme.onPrimaryContainer,
                      unselectedLabelColor: colorScheme.onSurfaceVariant,
                      dividerColor: Colors.transparent,
                      indicatorSize: TabBarIndicatorSize.tab,
                      indicator: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: colorScheme.primaryContainer,
                      ),
                      tabs: const [
                        Tab(
                          height: 36,
                          child: Text(
                            'Movies',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Tab(
                          height: 36,
                          child: Text(
                            'TV Shows',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Tab(
                          height: 36,
                          child: Text(
                            'People',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Tab(
                          height: 36,
                          child: Text(
                            'Discover',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

            // Main result content area
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildMovieTab(),
                  _buildTvTab(),
                  _buildPeopleTab(),
                  DiscoverMoviesPage(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


  @override
  void dispose() {
    _debounce?.cancel();
    _tabController.dispose();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }
}
