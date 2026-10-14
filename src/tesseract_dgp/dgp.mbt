///|
/// Bridges `riantr/moonbit_doubleML`'s data-generating processes into `Dataset`.
///
/// The DGPs are seeded, so `irm_dataset(81, 4, 0.5, 42)` is the same 81 rows
/// on every machine and every run. That is what makes the assertions in
/// `record_test.mbt` statements about fixed numbers rather than about a run
/// that happened to pass - a fidelity test whose inputs move is a fidelity
/// test that cannot fail for the right reason.
///
/// Two of the seventeen available DGPs are wired up. They differ in a way that
/// matters here: `make_irm_data` draws a *binary* treatment, so half its `d`
/// column is exactly `0.0` or `1.0`, while `make_plr_CCDDHNR2018` draws a
/// continuous confounded one, so every `d` is an arbitrary double. A store
/// that mangles numbers would still survive the first and fail the second.

///|
/// One row per observation, taking the covariate row out of the design matrix.
fn rows_from(
  x : @moonbit_doubleML.Matrix,
  y : Array[Double],
  d : Array[Double],
  n_obs : Int32,
) -> Array[Observation] {
  let dim_x = x.cols()
  let out : Array[Observation] = []
  for i = 0; i < n_obs; i = i + 1 {
    let row : Array[Double] = []
    for j = 0; j < dim_x; j = j + 1 {
      row.push(x.get(i, j))
    }
    out.push({ index: i, d: d[i], y: y[i], x: row, })
  }
  out
}

///|
/// The IRM DGP of Chernozhukov et al. (2018) Section 4.2.
///
/// Binary treatment drawn from a logistic propensity, so `d` is exactly `0.0`
/// or `1.0`; the outcomes and covariates are not round numbers.
pub fn irm_dataset(
  n_obs : Int32,
  dim_x : Int32,
  theta : Double,
  seed : Int32,
) -> Dataset {
  let raw = @moonbit_doubleML.make_irm_data(n_obs, dim_x, theta, seed)
  {
    source: "make_irm_data",
    theta: raw.theta_get(),
    dim_x,
    observations: rows_from(raw.x_get(), raw.y_get(), raw.d_get(), n_obs),
  }
}

///|
/// The partially linear DGP of Chernozhukov et al. (2018) Figure 1.
///
/// The treatment `d` is confounded and continuous, so every value in the
/// column is an arbitrary double - the hardest of the two for a store to hold.
pub fn plr_dataset(
  n_obs : Int32,
  dim_x : Int32,
  theta : Double,
  seed : Int32,
) -> Dataset {
  let raw = @moonbit_doubleML.make_plr_CCDDHNR2018(n_obs, dim_x, theta, seed)
  {
    source: "make_plr_CCDDHNR2018",
    theta: raw.theta_get(),
    dim_x,
    observations: rows_from(raw.x_get(), raw.y_get(), raw.d_get(), n_obs),
  }
}
