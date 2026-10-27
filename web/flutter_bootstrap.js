// LabTrack staff portal: the standard Flutter loader, plus removing the
// "Loading…" screen from index.html once the app is ready to draw.
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    document.getElementById('loading')?.remove();
    await appRunner.runApp();
  },
});
