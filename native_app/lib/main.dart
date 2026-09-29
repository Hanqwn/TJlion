import 'package:flutter/material.dart';

import 'app/app_shell.dart';
import 'data/lion_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LionManagerApp());
}

class LionManagerApp extends StatelessWidget {
  const LionManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '狮队管理台',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF23372F)),
        scaffoldBackgroundColor: const Color(0xFFF6F2EA),
      ),
      home: const _RepositoryBootstrap(),
    );
  }
}

class _RepositoryBootstrap extends StatefulWidget {
  const _RepositoryBootstrap();

  @override
  State<_RepositoryBootstrap> createState() => _RepositoryBootstrapState();
}

class _RepositoryBootstrapState extends State<_RepositoryBootstrap> {
  late Future<LionRepository> _repositoryFuture;

  @override
  void initState() {
    super.initState();
    _repositoryFuture = LionRepository.open();
  }

  void _retry() {
    setState(() => _repositoryFuture = LionRepository.open());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LionRepository>(
      future: _repositoryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _RepositoryLoadingScreen();
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return _RepositoryErrorScreen(onRetry: _retry);
        }
        return AppShell(repository: snapshot.data!);
      },
    );
  }
}

class _RepositoryLoadingScreen extends StatelessWidget {
  const _RepositoryLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 18),
            Text('正在准备本地资料库…'),
          ],
        ),
      ),
    );
  }
}

class _RepositoryErrorScreen extends StatelessWidget {
  const _RepositoryErrorScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.storage_outlined, size: 42, color: colors.error),
                  const SizedBox(height: 18),
                  Text(
                    '无法打开本地资料库',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '请重试，或确认应用已获得本地存储空间。',
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: colors.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
