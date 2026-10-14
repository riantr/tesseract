///|
/// The Tesseract window.
///
/// The page is shipped as an asset under `cmd/gui/web/`, resolved against the
/// application resource directory: the repository root when `proton_cli dev`
/// or `moon run cmd/gui` runs from there, and the packaged `Resources/` tree
/// after a release. Nothing about the front end is generated, so the HTML is
/// an ordinary file that can be edited and reloaded.

///|
/// Path of the page, relative to the application resource directory.
const PAGE : String = "cmd/gui/web/index.html"

///|
/// Environment variable that turns on Chromium's remote debugging.
///
/// `proton_cli dev` already opens a DevTools endpoint; a packaged build does
/// not, because debug mode is off by default. Setting this makes a packaged
/// build behave the same way, which is what lets the packaged path be checked
/// with the same tooling as the dev path.
const DEBUG_ENV : String = "TESSERACT_DEBUG"

///|
async fn main {
  let debug = @env.get_env_var(DEBUG_ENV) is Some(_)
  @proton.asset("Tesseract", PAGE, width=1240, height=1000, resizable=true)
  .load_config()
  .debug(enabled=debug)
  .commands(fn(registrar) raise { register(registrar) })
  .run_or_abort()
}
