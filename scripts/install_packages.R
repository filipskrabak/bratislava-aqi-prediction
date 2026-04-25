req_pkgs <- c(
  "tidyverse","arrow","lubridate","tsibble","here","corrplot",
  "zoo","forecast","generics","fable","feasts","ggtime","tseries",
  "MASS","ranger","pROC","performance","brant","knitr","scales",
  "xgboost","kknn","vip"
)

installed <- rownames(installed.packages())
missing <- setdiff(unique(req_pkgs), installed)
if(length(missing) == 0) {
  message("All requested packages are already installed: ", paste(sort(unique(req_pkgs)), collapse=", "))
} else {
  message("Installing missing packages: ", paste(missing, collapse=", "))
  install.packages(missing, repos = "https://cran.rstudio.com", dependencies = TRUE)
  newly_installed <- intersect(unique(req_pkgs), rownames(installed.packages()))
  message("Now installed: ", paste(sort(newly_installed), collapse=", "))
}

invisible(NULL)
