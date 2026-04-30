# Libraries 
library(conflicted)
library(shiny)
library(bslib)
library(MASS)
library(VGAM)
library(tidyverse)
library(arrow)
library(lubridate)
library(tsibble)
library(zoo)
library(here)
library(ranger)
library(xgboost)
library(kknn)
library(glmnet)
library(rpart)
library(rpart.plot)
library(vip)
library(pROC)
library(PRROC)
library(patchwork)
library(scales)
library(car)      # poTest (via performance/brant)
library(fable)
library(feasts)

conflict_prefer("filter", "dplyr")
conflict_prefer("lag", "dplyr")
conflict_prefer("select", "dplyr")
conflict_prefer("interval", "tsibble")
conflict_prefer("vi", "vip")
conflict_prefer("recode", "car")

# Constants 
aqi_levels <- c("Good", "Fair", "Moderate", "Poor")
aqi_colors <- c(Good = "#50f0e6", Fair = "#50ccaa", Moderate = "#f0e641", Poor = "#ff5050")
pollutant_colors <- c(
  "PM2.5"       = "#960032",
  "PM10"        = "#ff5050",
  "NO2"         = "#f0e641",
  "O3"          = "#50ccaa",
  "SO2"         = "#50f0e6",
  "Tie/Missing" = "#cccccc"
)

# RF hyperparameters
RF_NUM_TREES     <- 500
RF_MAX_DEPTH     <- NULL
RF_N_THREADS     <- max(1, parallel::detectCores() - 1)
RF_SEED          <- 2026
RF_WEIGHT_POWER  <- 1.2
RF_MTRY_A        <- 2
RF_MIN_NODE_SIZE_A <- 20
RF_MTRY_B        <- 3
RF_MIN_NODE_SIZE_B <- 20

# XGBoost hyperparameters
XGB_BOOSTER      <- "gbtree"
XGB_OBJECTIVE    <- "multi:softmax"
XGB_ETA          <- 0.1
XGB_SUBSAMPLE    <- 0.8
XGB_COLSAMPLE    <- 0.8
XGB_WEIGHT_POWER <- 0.8
XGB_NTHREAD      <- max(1, parallel::detectCores() - 1)
XGB_MAX_DEPTH_A  <- 5;  XGB_MIN_CHILD_WEIGHT_A <- 10; XGB_NROUNDS_A <- 100
XGB_MAX_DEPTH_B  <- 6;  XGB_MIN_CHILD_WEIGHT_B <- 10; XGB_NROUNDS_B <- 100

# kNN hyperparameters
KNN_DISTANCE  <- 2
KNN_K_A       <- 26;  KNN_KERNEL_A <- "triangular"
KNN_K_B       <- 20;  KNN_KERNEL_B <- "triangular"

# Ordinal / Multinomial / Partial weights
ORDINAL_WEIGHT_POWER     <- 0.7
MULTINOMIAL_WEIGHT_POWER <- 0.7

# Scenario 3 glmnet
LASSO_ALPHA   <- 1.0
ELNET_ALPHA   <- 0.5
GLMNET_NFOLDS <- 10

# Scenario 4 tree
TREE_MAXDEPTH  <- 5
TREE_CP        <- 0.001
TREE_MINSPLIT  <- 20
TREE_MINBUCKET <- 7

# =============================================================================
# PREPROCESSING PIPELINE
# =============================================================================
build_data <- function() {
  message("Building preprocessed data ...")

  #  Step 1: Pollutants 
  pollutants_data  <- open_dataset(here("pollutants"))
  filtered_air_data <- pollutants_data %>%
    select(Start, Pollutant, Value, Samplingpoint, Validity) %>%
    filter(grepl("SK0001A", Samplingpoint)) %>%
    filter(year(Start) >= 2017, year(Start) <= 2024) %>%
    collect()

  clean_air_data <- filtered_air_data %>%
    mutate(Pollutant_Name = case_when(
      Pollutant == 1    ~ "SO2",
      Pollutant == 5    ~ "PM10",
      Pollutant == 7    ~ "O3",
      Pollutant == 8    ~ "NO2",
      Pollutant == 6001 ~ "PM2.5"
    )) %>%
    select(Start, Pollutant_Name, Value) %>%
    pivot_wider(names_from = Pollutant_Name, values_from = Value) %>%
    arrange(Start) %>%
    as_tsibble(index = Start) %>%
    fill_gaps() %>%
    mutate(across(c(SO2, PM10, O3, NO2, `PM2.5`), ~ pmax(., 0, na.rm = FALSE))) %>%
    mutate(across(c(SO2, PM10, O3, NO2, `PM2.5`),
                  ~ zoo::na.approx(., na.rm = FALSE, maxgap = 3)))

  #  Step 2: Weather ─
  weather_file_path <- here("weather", "open-meteo-48.12N17.10E163m.csv")

  weather_data <- read_csv(weather_file_path, skip = 3, show_col_types = FALSE) %>%
    rename(
      Start                = time,
      Temperature          = `temperature_2m (°C)`,
      Humidity             = `relative_humidity_2m (%)`,
      Dew_Point            = `dew_point_2m (°C)`,
      Apparent_Temp        = `apparent_temperature (°C)`,
      Rain                 = `rain (mm)`,
      Precipitation        = `precipitation (mm)`,
      Snow_Depth           = `snow_depth (m)`,
      Snowfall             = `snowfall (cm)`,
      Weather_Code         = `weather_code (wmo code)`,
      Pressure_MSL         = `pressure_msl (hPa)`,
      Cloud_Cover          = `cloud_cover (%)`,
      Surface_Pressure     = `surface_pressure (hPa)`,
      Cloud_Cover_Low      = `cloud_cover_low (%)`,
      Cloud_Cover_Mid      = `cloud_cover_mid (%)`,
      Cloud_Cover_High     = `cloud_cover_high (%)`,
      ET0                  = `et0_fao_evapotranspiration (mm)`,
      Vapour_Pressure_Def  = `vapour_pressure_deficit (kPa)`,
      Wind_Speed           = `wind_speed_10m (km/h)`,
      Wind_Speed_100m      = `wind_speed_100m (km/h)`,
      Wind_Direction       = `wind_direction_10m (°)`,
      Wind_Gusts           = `wind_gusts_10m (km/h)`,
      Wind_Direction_100m  = `wind_direction_100m (°)`,
      Soil_Temp_0_7        = `soil_temperature_0_to_7cm (°C)`,
      Soil_Temp_7_28       = `soil_temperature_7_to_28cm (°C)`,
      Soil_Temp_28_100     = `soil_temperature_28_to_100cm (°C)`,
      Soil_Temp_100_255    = `soil_temperature_100_to_255cm (°C)`,
      Soil_Moisture_0_7    = `soil_moisture_0_to_7cm (m³/m³)`,
      Soil_Moisture_7_28   = `soil_moisture_7_to_28cm (m³/m³)`,
      Soil_Moisture_28_100 = `soil_moisture_28_to_100cm (m³/m³)`,
      Soil_Moisture_100_255 = `soil_moisture_100_to_255cm (m³/m³)`
    ) %>%
    filter(year(Start) >= 2017, year(Start) <= 2024) %>%
    select(-c(Wind_Speed_100m, Wind_Direction_100m,
              Soil_Temp_7_28, Soil_Temp_28_100, Soil_Temp_100_255,
              Soil_Moisture_7_28, Soil_Moisture_28_100, Soil_Moisture_100_255,
              Surface_Pressure, Apparent_Temp, Snow_Depth, ET0))

  #  Step 3: Merge + AQI labels ─
  merged_data <- as_tibble(clean_air_data) %>%
    inner_join(weather_data, by = "Start")

  complete_data <- merged_data %>%
    mutate(
      AQI_PM2.5 = case_when(`PM2.5`<=5~1L,`PM2.5`<=15~2L,`PM2.5`<=50~3L,`PM2.5`<=90~4L,`PM2.5`<=140~5L,`PM2.5`>140~6L),
      AQI_PM10  = case_when(PM10<=15~1L,PM10<=45~2L,PM10<=120~3L,PM10<=195~4L,PM10<=270~5L,PM10>270~6L),
      AQI_O3    = case_when(O3<=60~1L,O3<=100~2L,O3<=120~3L,O3<=160~4L,O3<=180~5L,O3>180~6L),
      AQI_NO2   = case_when(NO2<=10~1L,NO2<=25~2L,NO2<=60~3L,NO2<=100~4L,NO2<=150~5L,NO2>150~6L),
      AQI_SO2   = case_when(SO2<=20~1L,SO2<=40~2L,SO2<=125~3L,SO2<=190~4L,SO2<=275~5L,SO2>275~6L),
      AQI = pmin(pmax(AQI_PM2.5, AQI_PM10, AQI_O3, AQI_NO2, AQI_SO2, na.rm = TRUE), 4L),
      AQI_Label = factor(c("Good","Fair","Moderate","Poor")[AQI],
                         levels = c("Good","Fair","Moderate","Poor"), ordered = TRUE)
    )

  #  Step 4: Feature engineering 
  model_features <- complete_data %>%
    as_tibble() %>%
    arrange(Start) %>%
    transmute(
      Start,
      AQI_p24  = lead(AQI, 24),
      AQI_t    = AQI,
      AQI_t1   = lag(AQI, 1),
      AQI_t2   = lag(AQI, 2),
      AQI_t24  = lag(AQI, 24),
      PM25     = `PM2.5`,
      PM10     = PM10,
      NO2      = NO2,
      O3       = O3,
      SO2      = SO2,
      hour     = hour(Start),
      month    = month(Start),
      across(c(Temperature, Humidity, Dew_Point, Rain, Precipitation,
               Snowfall, Weather_Code, Pressure_MSL, Cloud_Cover,
               Cloud_Cover_Low, Cloud_Cover_Mid, Cloud_Cover_High,
               Vapour_Pressure_Def, Wind_Speed, Wind_Direction, Wind_Gusts,
               Soil_Temp_0_7, Soil_Moisture_0_7))
    ) %>%
    drop_na() %>%
    mutate(Weather_Code = case_when(
      Weather_Code %in% c(0, 1, 2, 3)   ~ 1L,
      Weather_Code %in% c(51, 53, 55)   ~ 2L,
      Weather_Code %in% c(61, 63, 65)   ~ 3L,
      Weather_Code %in% c(71, 73, 75)   ~ 4L,
      TRUE ~ 1L
    ))

  #  Partitions 
  PARTITION_A <- c("AQI_t","AQI_t1","AQI_t2","AQI_t24",
                   "PM25","PM10","NO2","O3","SO2","hour","month")
  FEATURES_TO_REMOVE <- c("Precipitation","Humidity","Vapour_Pressure_Def",
                           "Soil_Temp_0_7","Temperature","Wind_Gusts","PM10")
  PARTITION_B_ALL <- model_features %>% select(-Start, -AQI_p24) %>% names()
  PARTITION_B     <- setdiff(PARTITION_B_ALL, FEATURES_TO_REMOVE)

  #  Train / Test split 
  make_split_set <- function(df) {
    df %>%
      select(-Start) %>%
      mutate(AQI_p24 = factor(pmin(AQI_p24, 4L), levels = 1:4, ordered = TRUE))
  }

  train_data <- model_features %>% filter(year(Start) <= 2022) %>% make_split_set()
  test_data  <- model_features %>% filter(year(Start) >= 2023) %>% make_split_set()

  result <- list(
    model_features = model_features,
    train_data     = train_data,
    test_data      = test_data,
    PARTITION_A    = PARTITION_A,
    PARTITION_B    = PARTITION_B,
    complete_data  = complete_data
  )

  result
}

# =============================================================================
# METRICS HELPERS
# =============================================================================
macro_f1 <- function(preds_int, actual_int) {
  f1s <- sapply(1:4, function(k) {
    tp <- sum(preds_int == k & actual_int == k)
    fp <- sum(preds_int == k & actual_int != k)
    fn <- sum(preds_int != k & actual_int == k)
    if (tp == 0) return(0)
    p <- tp / (tp + fp); r <- tp / (tp + fn); 2 * p * r / (p + r)
  })
  round(mean(f1s), 4)
}

compute_metrics <- function(preds, actual) {
  keep <- !is.na(actual); preds <- preds[keep]; actual <- actual[keep]
  tibble(
    `Acc (%)`          = round(100 * mean(preds == actual), 2),
    `+-1 Class Acc (%)` = round(100 * mean(abs(preds - actual) <= 1), 2),
    `Macro F1`         = macro_f1(preds, actual),
    `Poor Recall (%)`  = round(100 * mean(preds[actual == 4] == 4), 2)
  )
}

compute_class_recall <- function(preds, actual) {
  keep <- !is.na(actual); preds <- preds[keep]; actual <- actual[keep]
  tibble(Class = 1:4, Label = aqi_levels) %>%
    mutate(
      Actual_n    = map_int(Class, \(k) sum(actual == k)),
      Pred_n      = map_int(Class, \(k) sum(preds == k)),
      `Recall (%)` = map_dbl(Class, \(k) {
        n <- sum(actual == k)
        if (n == 0) NA_real_ else round(100 * mean(preds[actual == k] == k), 1)
      })
    )
}

plot_confusion_matrix <- function(actual, preds, title = "") {
  tibble(Actual = actual, Predicted = preds) %>%
    mutate(
      Actual    = factor(Actual,    levels = 1:4, labels = aqi_levels),
      Predicted = factor(Predicted, levels = 1:4, labels = aqi_levels)
    ) %>%
    count(Actual, Predicted) %>%
    complete(Actual, Predicted, fill = list(n = 0)) %>%
    mutate(Recall = n / sum(n), .by = Actual) %>%
    ggplot(aes(Predicted, Actual, fill = Recall)) +
    geom_tile(color = "white", linewidth = 0.5) +
    geom_text(
      aes(label = if_else(n > 0, sprintf("%.0f%%\n(n=%d)", Recall * 100, n), "")),
      size = 2.8, lineheight = 1.2
    ) +
    scale_fill_gradient(low = "white", high = "steelblue",
                        labels = scales::percent, limits = c(0, 1)) +
    scale_x_discrete(position = "top") +
    scale_y_discrete(limits = rev(aqi_levels)) +
    labs(title = title,
         x = "Predicted class", y = "True (Actual) class", fill = "Recall") +
    theme_minimal()
}

# =============================================================================
# MODEL FITTING FUNCTIONS
# =============================================================================

#  Class weights ─
compute_class_weights_rf <- function(train_data, power = RF_WEIGHT_POWER) {
  class_counts <- table(train_data$AQI_p24)
  weights <- (1 / as.numeric(class_counts))^power
  weights[as.integer(train_data$AQI_p24)]
}

compute_class_weights_xgb <- function(data, power = XGB_WEIGHT_POWER) {
  class_counts <- table(data$AQI_p24)
  w_raw    <- (1 / as.numeric(class_counts))^power
  w_per_row <- w_raw[as.integer(data$AQI_p24)]
  w_per_row / mean(w_per_row)
}

compute_class_weights_ordinal <- function(train_data, power = ORDINAL_WEIGHT_POWER) {
  class_counts <- table(train_data$AQI_p24)
  w_raw    <- (1 / as.numeric(class_counts))^power
  w_per_row <- w_raw[as.integer(as.character(train_data$AQI_p24))]
  w_per_row / sum(w_per_row, na.rm = TRUE) * nrow(train_data)
}

compute_class_weights_multinomial <- function(train_data, power = MULTINOMIAL_WEIGHT_POWER) {
  class_counts <- table(train_data$AQI_p24)
  w_raw    <- (1 / as.numeric(class_counts))^power
  w_per_row <- w_raw[as.integer(as.character(train_data$AQI_p24))]
  w_per_row / sum(w_per_row, na.rm = TRUE) * nrow(train_data)
}

#  Random Forest ─
fit_rf <- function(train_data, partition, mtry = NULL, min_node_size = 1,
                   weighted = TRUE, num_trees = RF_NUM_TREES,
                   weight_power = RF_WEIGHT_POWER) {
  train_subset <- train_data %>% select(all_of(c(partition, "AQI_p24")))
  weights <- if (weighted) compute_class_weights_rf(train_subset, power = weight_power) else NULL
  ranger(
    AQI_p24 ~ ., data = train_subset,
    num.trees = num_trees, mtry = mtry, importance = "permutation",
    min.node.size = min_node_size, max.depth = RF_MAX_DEPTH,
    num.threads = RF_N_THREADS, seed = RF_SEED, case.weights = weights
  )
}

predict_rf <- function(model, test_data, partition) {
  preds  <- as.integer(predict(model, data = test_data %>% select(all_of(partition)))$predictions)
  actual <- as.integer(test_data$AQI_p24)
  list(actual = actual, preds = preds)
}

#  XGBoost ─
create_dmatrix <- function(data, partition) {
  X <- data %>% select(all_of(partition)) %>% as.matrix()
  y <- as.integer(data$AQI_p24) - 1L
  xgb.DMatrix(X, label = y)
}

xgb_base_params <- list(
  booster          = XGB_BOOSTER,
  objective        = XGB_OBJECTIVE,
  num_class        = 4L,
  eta              = XGB_ETA,
  subsample        = XGB_SUBSAMPLE,
  colsample_bytree = XGB_COLSAMPLE,
  eval_metric      = "mlogloss",
  nthread          = XGB_NTHREAD
)

fit_xgb <- function(dtrain, nrounds, extra_params, train_data_for_weights,
                    weighted = TRUE, base_params = xgb_base_params,
                    weight_power = XGB_WEIGHT_POWER) {
  if (weighted) {
    w <- compute_class_weights_xgb(train_data_for_weights, power = weight_power)
    setinfo(dtrain, "weight", w)
  }
  params <- modifyList(base_params, extra_params)
  xgb.train(params = params, data = dtrain, nrounds = nrounds, verbose = 0)
}

predict_xgb <- function(model, dtest, test_data) {
  preds  <- as.integer(predict(model, dtest)) + 1L
  actual <- as.integer(test_data$AQI_p24)
  list(actual = actual, preds = preds)
}

#  kNN ─
fit_knn <- function(train_data, test_data, partition, k, kernel) {
  train_sub <- train_data %>% select(all_of(c(partition, "AQI_p24")))
  test_sub  <- test_data  %>% select(all_of(c(partition, "AQI_p24")))
  kknn(AQI_p24 ~ ., train = train_sub, test = test_sub,
       k = k, distance = KNN_DISTANCE, kernel = kernel, scale = TRUE)
}

predict_knn <- function(knn_fit, test_data) {
  preds  <- as.integer(fitted(knn_fit))
  actual <- as.integer(test_data$AQI_p24)
  list(actual = actual, preds = preds)
}

#  Ordinal Regression 
fit_ordinal <- function(train_data, partition, weight_power = ORDINAL_WEIGHT_POWER) {
  train_subset <- train_data %>% select(all_of(c(partition, "AQI_p24")))
  polr(AQI_p24 ~ ., data = train_subset, Hess = TRUE,
       weights = compute_class_weights_ordinal(train_subset, power = weight_power),
       method = "logistic")
}

predict_ordinal <- function(model, test_data, partition) {
  test_features <- test_data %>% select(all_of(partition))
  actual <- as.integer(as.character(test_data$AQI_p24))
  preds  <- as.integer(as.character(predict(model, newdata = test_features)))
  list(actual = actual, preds = preds)
}

polr_summary_table <- function(model) {
  tbl <- as.data.frame(coef(summary(model)))
  tbl$p_value <- pnorm(abs(tbl[, "t value"]), lower.tail = FALSE) * 2
  round(tbl[, c("Value", "Std. Error", "t value", "p_value")], 4)
}

#  Partial PO (Partition A only) 
fit_partial <- function(train_data, partition, weight_power = ORDINAL_WEIGHT_POWER) {
  train_subset <- train_data %>% select(all_of(c(partition, "AQI_p24")))
  vglm(AQI_p24 ~ ., data = train_subset,
       family = cumulative(parallel = TRUE ~ -1 + AQI_t2 + PM10),
       weights = compute_class_weights_ordinal(train_subset, power = weight_power))
}

predict_partial <- function(model, test_data, partition) {
  test_features <- test_data %>% select(all_of(partition))
  actual <- as.integer(test_data$AQI_p24)
  probs  <- predictvglm(model, newdata = test_features, type = "response")
  preds  <- max.col(probs)
  list(actual = actual, preds = preds)
}

#  Multinomial Regression 
fit_multinom <- function(train_data, partition, weight_power = MULTINOMIAL_WEIGHT_POWER) {
  train_subset <- train_data %>% select(all_of(c(partition, "AQI_p24")))
  train_subset$AQI_p24 <- as.factor(as.character(train_subset$AQI_p24))
  vglm(AQI_p24 ~ ., data = train_subset,
       family  = multinomial(refLevel = 1),
       model   = TRUE,
       weights = compute_class_weights_multinomial(train_subset, power = weight_power))
}

predict_multinom <- function(model, test_data, partition) {
  test_features <- test_data %>% select(all_of(partition))
  actual <- as.integer(as.character(test_data$AQI_p24))
  probs  <- predictvglm(model, newdata = test_features, type = "response")
  preds  <- max.col(probs)
  list(actual = actual, preds = preds)
}

#  Feature-selection helpers (Scenario 3) 
extract_kept_features <- function(cv_model, s = "lambda.1se") {
  coef_list <- coef(cv_model, s = s)
  bind_rows(lapply(names(coef_list), function(cl) {
    mat <- as.matrix(coef_list[[cl]])
    tibble(class = cl, feature = rownames(mat), coef = as.numeric(mat))
  })) %>%
    group_by(feature) %>%
    summarise(kept = any(coef != 0), .groups = "drop") %>%
    filter(feature != "(Intercept)")
}

# =============================================================================
# GLOBAL DATA LOADING  (runs once at startup)
# =============================================================================
message("=== Building data ===")
app_data <- build_data()

model_features <- app_data$model_features
train_data     <- app_data$train_data
test_data      <- app_data$test_data
PARTITION_A    <- app_data$PARTITION_A
PARTITION_B    <- app_data$PARTITION_B
complete_data  <- app_data$complete_data

aqi_drivers <- complete_data %>%
  as_tibble() %>%
  filter(!is.na(AQI), AQI > 1) %>%
  mutate(
    n_tied = (AQI_PM2.5 == AQI) + (AQI_PM10 == AQI) +
             (AQI_O3    == AQI) + (AQI_NO2   == AQI) +
             (AQI_SO2   == AQI),
    driver = case_when(
      is.na(n_tied) | n_tied != 1 ~ "Tie/Missing",
      AQI_PM2.5 == AQI        ~ "PM2.5",
      AQI_PM10  == AQI        ~ "PM10",
      AQI_NO2   == AQI        ~ "NO2",
      AQI_O3    == AQI        ~ "O3",
      AQI_SO2   == AQI        ~ "SO2",
      TRUE                    ~ "Tie/Missing"
    )
  )

# XGB prediction wrapper (defined globally so reactives can use it)
xgb_pred_wrapper <- function(object, newdata) {
  dm    <- xgb.DMatrix(as.matrix(newdata))
  preds <- as.integer(predict(object, dm)) + 1L
  factor(as.character(preds), levels = c("1", "2", "3", "4"))
}

# =============================================================================
# UI
# =============================================================================
ui <- page_navbar(
  title = "AQI Forecasting (Bratislava)",
  theme = bs_theme(
    bootswatch = "simplex",
    base_font  = font_google("Inter")
  ),
  bg = "#2c3e50",

  #  Tab 1: Data Overview 
  nav_panel("Data Overview",
    navset_card_tab(
      nav_panel("Overview",
        layout_columns(
          col_widths = c(12),
          card(
            card_header("Weekly Average AQI (2017–2024)"),
            plotOutput("plot_ts", height = "280px")
          )
        ),
        layout_columns(
          col_widths = c(4, 4, 4),
          card(card_header("Class Distribution"),  plotOutput("plot_dist",    height = "260px")),
          card(card_header("Monthly AQI by Year (Seasonal)"), plotOutput("plot_heatmap", height = "260px")),
          card(card_header("AQI Drivers by Class"), plotOutput("plot_corr", height = "340px"))
        ),
        card(
          card_header("Pollutant Distributions by AQI Class"),
          plotOutput("plot_boxplots", height = "320px")
        )
      ),
      nav_panel("STL Decomposition",
        card(
          card_header("STL Decomposition of AQI (annual + weekly + daily seasonality)"),
          plotOutput("plot_stl", height = "680px")
        )
      )
    )
  ),

  #  Tab 2: Model Comparison (Scenarios 1 + 2) 
  nav_panel("Model Comparison",
    layout_sidebar(
      sidebar = sidebar(
        width = 290,

        #  Train All button 
        actionButton("btn_train_all", "Train All Models",
                     class = "btn-success w-100", icon = icon("play")),
        hr(),

        #  Individual model training ─
        h6(strong("Individual Models")),
        accordion(
          open = FALSE,
          accordion_panel(
            "Random Forest",
            actionButton("btn_train_rf", "Train RF", class = "btn-primary btn-sm w-100"),
            br(), br(),
            sliderInput("inp_rf_num_trees",  "# Trees",        100, 1000, 500, step = 100),
            sliderInput("inp_rf_mtry_a",     "mtry (Part. A)", 1,   11,   5,   step = 1),
            sliderInput("inp_rf_min_node_a", "Min node (A)",   5,   50,   20,  step = 5),
            sliderInput("inp_rf_mtry_b",     "mtry (Part. B)", 1,   22,   3,   step = 1),
            sliderInput("inp_rf_min_node_b", "Min node (B)",   5,   50,   20,  step = 5),
            sliderInput("inp_rf_weight_power", "Weight power",  0.1, 3.0,  1.2, step = 0.1)
          ),
          accordion_panel(
            "XGBoost",
            actionButton("btn_train_xgb", "Train XGBoost", class = "btn-primary btn-sm w-100"),
            br(), br(),
            sliderInput("inp_xgb_eta",         "Learning rate",  0.01, 0.30, 0.10, step = 0.01),
            sliderInput("inp_xgb_subsample",   "Subsample",      0.5,  1.0,  0.8,  step = 0.1),
            sliderInput("inp_xgb_colsample",   "Col. sample",    0.5,  1.0,  0.8,  step = 0.1),
            sliderInput("inp_xgb_max_depth_a", "Max depth (A)",  2,    10,   4,    step = 1),
            sliderInput("inp_xgb_nrounds_a",   "Rounds (A)",     50,   500,  200,  step = 50),
            sliderInput("inp_xgb_max_depth_b", "Max depth (B)",  2,    10,   6,    step = 1),
            sliderInput("inp_xgb_nrounds_b",   "Rounds (B)",     50,   500,  200,  step = 50),
            sliderInput("inp_xgb_weight_power", "Weight power",  0.1,  3.0,  0.8,  step = 0.1)
          ),
          accordion_panel(
            "kNN",
            actionButton("btn_train_knn", "Train kNN", class = "btn-primary btn-sm w-100"),
            br(), br(),
            sliderInput("inp_knn_k_a", "k (Part. A)", 5, 80, 30, step = 5),
            sliderInput("inp_knn_k_b", "k (Part. B)", 5, 80, 20, step = 5)
          ),
          accordion_panel(
            "Ordinal Regression",
            actionButton("btn_train_ord", "Train Ordinal Reg.", class = "btn-primary btn-sm w-100"),
            br(), br(),
            sliderInput("inp_ord_weight_power", "Weight power", 0.1, 3.0, 0.7, step = 0.1)
          ),
          accordion_panel(
            "Partial PO",
            actionButton("btn_train_par", "Train Partial PO", class = "btn-primary btn-sm w-100"),
            br(), br(),
            sliderInput("inp_par_weight_power", "Weight power", 0.1, 3.0, 0.7, step = 0.1)
          ),
          accordion_panel(
            "Multinomial Reg.",
            actionButton("btn_train_mul", "Train Multinomial Reg.", class = "btn-primary btn-sm w-100"),
            br(), br(),
            sliderInput("inp_mul_weight_power", "Weight power", 0.1, 3.0, 0.7, step = 0.1)
          )
        ),
        hr(),
        p(em("Partial PO is only available for Partition A."), style = "font-size:0.82em; color:#888;")
      ),
      navset_card_tab(
        nav_panel("Overview",
          layout_columns(
            col_widths = c(12),
            card(
              card_header("All Models - Overall Metrics"),
              tableOutput("tbl_summary")
            )
          ),
          layout_columns(
            col_widths = c(6, 6),
            card(card_header("Macro F1 by Model"),        plotOutput("plot_f1_bar",      height = "340px")),
            card(card_header("Per-class Recall Heatmap"), plotOutput("plot_recall_heat", height = "340px"))
          )
        ),
        nav_panel("Confusion Matrix",
          card(
            card_header("Confusion Matrix"),
            layout_columns(
              col_widths = c(4, 4, 12),
              selectInput("cmp_model", "Model",
                          choices = c("Random Forest", "XGBoost", "kNN",
                                      "Ordinal Reg.", "Partial PO", "Multinomial Reg.")),
              selectInput("cmp_partition", "Partition",
                          choices = c("A (pollutants)", "B (all features)"),
                          selected = "B (all features)"),
              plotOutput("plot_cm", height = "480px")
            )
          )
        ),
        nav_panel("Feature Importance",
          card(
            card_header("RF vs XGBoost Feature Importance"),
            plotOutput("plot_imp", height = "480px")
          )
        ),
        nav_panel("Precision-Recall",
          card(
            card_header("Poor-class Precision-Recall Curve"),
            plotOutput("plot_pr", height = "480px")
          )
        )
      )
    )
  ),

  #  Tab 3: Scenario 3 - Feature Selection 
  nav_panel("Scenario 3: Feature Selection",
    layout_sidebar(
      sidebar = sidebar(
        width = 240,
        actionButton("btn_train_sc3", "Run Feature Selection",
                     class = "btn-success w-100", icon = icon("play"))
      ),
      navset_card_tab(
        nav_panel("Results",
          layout_columns(
            col_widths = c(12),
            card(
              card_header("Performance Comparison"),
              tableOutput("tbl_sc3")
            )
          ),
          layout_columns(
            col_widths = c(6, 6),
            card(card_header("Per-class Recall"),        plotOutput("plot_sc3_recall",  height = "340px")),
            card(card_header("Feature Retention Table"), tableOutput("tbl_sc3_features"))
          )
        ),
        nav_panel("CV Lambda Curves",
          layout_columns(
            col_widths = c(6, 6),
            card(card_header("Lasso — CV misclassification vs. log(λ)"),     plotOutput("plot_lasso_cv",  height = "420px")),
            card(card_header("Elastic Net — CV misclassification vs. log(λ)"), plotOutput("plot_elnet_cv", height = "420px"))
          )
        )
      )
    )
  ),

  #  Tab 4: Scenario 4 - Decision Trees ─
  nav_panel("Scenario 4: Decision Trees",
    layout_sidebar(
      sidebar = sidebar(
        width = 240,
        actionButton("btn_train_sc4", "Train Trees",
                     class = "btn-success w-100", icon = icon("play")),
        hr(),
        h6(strong("Hyperparameters")),
        sliderInput("inp_tree_maxdepth",  "Max depth",   2,  12, 5,  step = 1),
        numericInput("inp_tree_cp",       "CP",          value = 0.001, min = 0.0001, max = 0.05, step = 0.0005),
        sliderInput("inp_tree_minsplit",  "Min split",   5,  50, 20, step = 5),
        sliderInput("inp_tree_minbucket", "Min bucket",  2,  20, 7,  step = 1),
        hr(),
        checkboxInput("chk_tree_balanced", "Show balanced (weighted) tree", value = FALSE)
      ),
      navset_card_tab(
        nav_panel("Tree Visualization",
          layout_columns(
            col_widths = c(12),
            card(
              card_header("Decision Tree (Partition B)"),
              plotOutput("plot_tree", height = "700px")
            )
          )
        ),
        nav_panel("Metrics & Diagnostics",
          layout_columns(
            col_widths = c(7, 5),
            card(card_header("Depth vs. RF Agreement & Accuracy"), plotOutput("plot_depth_sweep", height = "360px")),
            card(
              card_header("Tree vs. RF metrics"),
              tableOutput("tbl_tree_metrics")
            )
          ),
          layout_columns(
            col_widths = c(6, 6),
            card(card_header("Confusion Matrix - Tree (unweighted)"), plotOutput("plot_tree_cm",     height = "340px")),
            card(card_header("Confusion Matrix - Tree (balanced)"),   plotOutput("plot_tree_cm_bal", height = "340px"))
          )
        )
      )
    )
  ),

  #  Tab 5: Prediction Lookup 
  nav_panel("Prediction Lookup",
    layout_columns(
      col_widths = c(4, 8),
      card(
        card_header("Input Features"),
        sliderInput("inp_aqit",   "Current AQI (AQI_t)", 1, 4, 2, step = 1),
        sliderInput("inp_aqit1",  "AQI lag 1 (AQI_t1)",  1, 4, 2, step = 1),
        sliderInput("inp_aqit2",  "AQI lag 2 (AQI_t2)",  1, 4, 2, step = 1),
        sliderInput("inp_aqit24", "AQI lag 24 (AQI_t24)", 1, 4, 2, step = 1),
        sliderInput("inp_pm25",   "PM2.5 (µg/m³)",  0, 100, 15),
        sliderInput("inp_pm10",   "PM10 (µg/m³)",   0, 150, 25),
        sliderInput("inp_no2",    "NO₂ (µg/m³)",    0, 100, 15),
        sliderInput("inp_o3",     "O₃ (µg/m³)",     0, 200, 60),
        sliderInput("inp_so2",    "SO₂ (µg/m³)",    0, 100, 10),
        sliderInput("inp_hour",   "Hour of day",    0, 23, 12, step = 1),
        sliderInput("inp_month",  "Month",          1, 12, 6, step = 1),
        actionButton("btn_predict", "Predict", class = "btn-primary w-100")
      ),
      card(
        card_header("XGBoost Prediction (Partition A)"),
        tableOutput("tbl_predictions"),
        br(),
        p(em("XGBoost A predicts next-24h AQI using pollutant + time features. Train XGBoost first."),
          style = "color:#888; font-size:0.85em;")
      )
    )
  )
)

# =============================================================================
# SERVER
# =============================================================================
server <- function(input, output, session) {

  #  Model store 
  # Single reactiveVal holding all trained models as a named list.
  # Keys: rf_A, rf_B, rf_B_prob, dtrain_A, dtrain_B, dtest_A, dtest_B,
  #       xgb_A, xgb_B, xgb_imp_perm_B, knn_A, knn_B,
  #       ordinal_A, ordinal_B, partial_A, multinomial_A, multinomial_B
  rv_models <- reactiveVal(list())

  # Separate store for Scenario 4 decision trees
  rv_sc4 <- reactiveVal(NULL)

  # Helper: build local XGB base params from current slider values
  local_xgb_params <- function() {
    modifyList(xgb_base_params, list(
      eta              = input$inp_xgb_eta,
      subsample        = input$inp_xgb_subsample,
      colsample_bytree = input$inp_xgb_colsample
    ))
  }

  #  Train RF 
  observeEvent(input$btn_train_rf, {
    withProgress(message = "Training Random Forest...", value = 0, {
      setProgress(0.2, detail = "RF A...")
      rf_A <- fit_rf(train_data, PARTITION_A,
                     mtry = input$inp_rf_mtry_a, min_node_size = input$inp_rf_min_node_a,
                     num_trees = input$inp_rf_num_trees, weight_power = input$inp_rf_weight_power)
      setProgress(0.55, detail = "RF B...")
      rf_B <- fit_rf(train_data, PARTITION_B,
                     mtry = input$inp_rf_mtry_b, min_node_size = input$inp_rf_min_node_b,
                     num_trees = input$inp_rf_num_trees, weight_power = input$inp_rf_weight_power)
      setProgress(0.85, detail = "RF probability forest...")
      rf_B_prob <- ranger(
        AQI_p24 ~ .,
        data = train_data %>% select(all_of(c(PARTITION_B, "AQI_p24"))),
        num.trees = input$inp_rf_num_trees, mtry = input$inp_rf_mtry_b,
        min.node.size = input$inp_rf_min_node_b,
        num.threads = RF_N_THREADS, seed = RF_SEED,
        case.weights = compute_class_weights_rf(train_data, power = input$inp_rf_weight_power),
        probability = TRUE
      )
      setProgress(1.0)
      rv_models(modifyList(rv_models(), list(rf_A = rf_A, rf_B = rf_B, rf_B_prob = rf_B_prob)))
    })
  })

  #  Train XGBoost 
  observeEvent(input$btn_train_xgb, {
    lp <- local_xgb_params()
    withProgress(message = "Training XGBoost...", value = 0, {
      setProgress(0.1, detail = "Building DMatrices...")
      dtrain_A <- create_dmatrix(train_data, PARTITION_A)
      dtrain_B <- create_dmatrix(train_data, PARTITION_B)
      dtest_A  <- create_dmatrix(test_data,  PARTITION_A)
      dtest_B  <- create_dmatrix(test_data,  PARTITION_B)
      setProgress(0.30, detail = "XGBoost A...")
      xgb_A <- fit_xgb(dtrain_A, input$inp_xgb_nrounds_a,
                        list(max_depth = input$inp_xgb_max_depth_a, min_child_weight = XGB_MIN_CHILD_WEIGHT_A),
                        train_data, base_params = lp, weight_power = input$inp_xgb_weight_power)
      setProgress(0.60, detail = "XGBoost B...")
      xgb_B <- fit_xgb(dtrain_B, input$inp_xgb_nrounds_b,
                        list(max_depth = input$inp_xgb_max_depth_b, min_child_weight = XGB_MIN_CHILD_WEIGHT_B),
                        train_data, base_params = lp, weight_power = input$inp_xgb_weight_power)
      setProgress(0.82, detail = "Permutation importance...")
      set.seed(2026)
      xgb_imp_perm_B <- vi(
        object = xgb_B, method = "permute",
        train = test_data %>% select(all_of(PARTITION_B)),
        target = test_data$AQI_p24, metric = "accuracy",
        pred_wrapper = xgb_pred_wrapper, nsim = 5
      )
      setProgress(1.0)
      rv_models(modifyList(rv_models(), list(
        dtrain_A = dtrain_A, dtrain_B = dtrain_B, dtest_A = dtest_A, dtest_B = dtest_B,
        xgb_A = xgb_A, xgb_B = xgb_B, xgb_imp_perm_B = xgb_imp_perm_B
      )))
    })
  })

  #  Train kNN 
  observeEvent(input$btn_train_knn, {
    withProgress(message = "Training kNN...", value = 0, {
      setProgress(0.3, detail = "kNN A...")
      knn_A <- fit_knn(train_data, test_data, PARTITION_A, input$inp_knn_k_a, KNN_KERNEL_A)
      setProgress(0.7, detail = "kNN B...")
      knn_B <- fit_knn(train_data, test_data, PARTITION_B, input$inp_knn_k_b, KNN_KERNEL_B)
      setProgress(1.0)
      rv_models(modifyList(rv_models(), list(knn_A = knn_A, knn_B = knn_B)))
    })
  })

  #  Train Ordinal Regression ─
  observeEvent(input$btn_train_ord, {
    withProgress(message = "Training Ordinal Regression...", value = 0, {
      setProgress(0.35, detail = "Ordinal A...")
      ordinal_A <- fit_ordinal(train_data, PARTITION_A, weight_power = input$inp_ord_weight_power)
      setProgress(0.75, detail = "Ordinal B...")
      ordinal_B <- fit_ordinal(train_data, PARTITION_B, weight_power = input$inp_ord_weight_power)
      setProgress(1.0)
      rv_models(modifyList(rv_models(), list(ordinal_A = ordinal_A, ordinal_B = ordinal_B)))
    })
  })

  #  Train Partial PO 
  observeEvent(input$btn_train_par, {
    withProgress(message = "Training Partial PO...", value = 0, {
      setProgress(0.5, detail = "Fitting...")
      partial_A <- fit_partial(train_data, PARTITION_A, weight_power = input$inp_par_weight_power)
      setProgress(1.0)
      rv_models(modifyList(rv_models(), list(partial_A = partial_A)))
    })
  })

  #  Train Multinomial Regression ─
  observeEvent(input$btn_train_mul, {
    withProgress(message = "Training Multinomial Regression...", value = 0, {
      setProgress(0.35, detail = "Multinomial A...")
      multinomial_A <- fit_multinom(train_data, PARTITION_A, weight_power = input$inp_mul_weight_power)
      setProgress(0.75, detail = "Multinomial B...")
      multinomial_B <- fit_multinom(train_data, PARTITION_B, weight_power = input$inp_mul_weight_power)
      setProgress(1.0)
      rv_models(modifyList(rv_models(), list(multinomial_A = multinomial_A, multinomial_B = multinomial_B)))
    })
  })

  #  Train All 
  observeEvent(input$btn_train_all, {
    withProgress(message = "Training all models...", value = 0, {
      lp <- modifyList(xgb_base_params, list(
        eta              = input$inp_xgb_eta,
        subsample        = input$inp_xgb_subsample,
        colsample_bytree = input$inp_xgb_colsample
      ))

      setProgress(0.04, detail = "RF A...")
      rf_A <- fit_rf(train_data, PARTITION_A,
                     mtry = input$inp_rf_mtry_a, min_node_size = input$inp_rf_min_node_a,
                     num_trees = input$inp_rf_num_trees, weight_power = input$inp_rf_weight_power)
      setProgress(0.10, detail = "RF B...")
      rf_B <- fit_rf(train_data, PARTITION_B,
                     mtry = input$inp_rf_mtry_b, min_node_size = input$inp_rf_min_node_b,
                     num_trees = input$inp_rf_num_trees, weight_power = input$inp_rf_weight_power)
      setProgress(0.16, detail = "RF probability forest...")
      rf_B_prob <- ranger(
        AQI_p24 ~ .,
        data = train_data %>% select(all_of(c(PARTITION_B, "AQI_p24"))),
        num.trees = input$inp_rf_num_trees, mtry = input$inp_rf_mtry_b,
        min.node.size = input$inp_rf_min_node_b,
        num.threads = RF_N_THREADS, seed = RF_SEED,
        case.weights = compute_class_weights_rf(train_data, power = input$inp_rf_weight_power),
        probability = TRUE
      )
      rv_models(modifyList(rv_models(), list(rf_A = rf_A, rf_B = rf_B, rf_B_prob = rf_B_prob)))

      setProgress(0.20, detail = "XGBoost matrices...")
      dtrain_A <- create_dmatrix(train_data, PARTITION_A)
      dtrain_B <- create_dmatrix(train_data, PARTITION_B)
      dtest_A  <- create_dmatrix(test_data,  PARTITION_A)
      dtest_B  <- create_dmatrix(test_data,  PARTITION_B)
      setProgress(0.28, detail = "XGBoost A...")
      xgb_A <- fit_xgb(dtrain_A, input$inp_xgb_nrounds_a,
                        list(max_depth = input$inp_xgb_max_depth_a, min_child_weight = XGB_MIN_CHILD_WEIGHT_A),
                        train_data, base_params = lp, weight_power = input$inp_xgb_weight_power)
      setProgress(0.38, detail = "XGBoost B...")
      xgb_B <- fit_xgb(dtrain_B, input$inp_xgb_nrounds_b,
                        list(max_depth = input$inp_xgb_max_depth_b, min_child_weight = XGB_MIN_CHILD_WEIGHT_B),
                        train_data, base_params = lp, weight_power = input$inp_xgb_weight_power)
      setProgress(0.46, detail = "XGBoost importance...")
      set.seed(2026)
      xgb_imp_perm_B <- vi(
        object = xgb_B, method = "permute",
        train = test_data %>% select(all_of(PARTITION_B)),
        target = test_data$AQI_p24, metric = "accuracy",
        pred_wrapper = xgb_pred_wrapper, nsim = 5
      )
      rv_models(modifyList(rv_models(), list(
        dtrain_A = dtrain_A, dtrain_B = dtrain_B, dtest_A = dtest_A, dtest_B = dtest_B,
        xgb_A = xgb_A, xgb_B = xgb_B, xgb_imp_perm_B = xgb_imp_perm_B
      )))

      setProgress(0.52, detail = "kNN A...")
      knn_A <- fit_knn(train_data, test_data, PARTITION_A, input$inp_knn_k_a, KNN_KERNEL_A)
      setProgress(0.57, detail = "kNN B...")
      knn_B <- fit_knn(train_data, test_data, PARTITION_B, input$inp_knn_k_b, KNN_KERNEL_B)
      rv_models(modifyList(rv_models(), list(knn_A = knn_A, knn_B = knn_B)))

      setProgress(0.62, detail = "Ordinal A...")
      ordinal_A <- fit_ordinal(train_data, PARTITION_A, weight_power = input$inp_ord_weight_power)
      setProgress(0.67, detail = "Ordinal B...")
      ordinal_B <- fit_ordinal(train_data, PARTITION_B, weight_power = input$inp_ord_weight_power)
      rv_models(modifyList(rv_models(), list(ordinal_A = ordinal_A, ordinal_B = ordinal_B)))

      setProgress(0.74, detail = "Partial PO...")
      partial_A <- fit_partial(train_data, PARTITION_A)
      rv_models(modifyList(rv_models(), list(partial_A = partial_A)))

      setProgress(0.82, detail = "Multinomial A...")
      multinomial_A <- fit_multinom(train_data, PARTITION_A, weight_power = input$inp_mul_weight_power)
      setProgress(0.90, detail = "Multinomial B...")
      multinomial_B <- fit_multinom(train_data, PARTITION_B, weight_power = input$inp_mul_weight_power)
      rv_models(modifyList(rv_models(), list(multinomial_A = multinomial_A, multinomial_B = multinomial_B)))

      setProgress(1.0, detail = "Done!")
    })
  })

  #  Train Trees (Scenario 4) ─
  observeEvent(input$btn_train_sc4, {
    m <- rv_models()
    withProgress(message = "Training decision trees (Scenario 4)...", value = 0, {
      setProgress(0.1, detail = "Tree (unweighted)...")
      tree_B <- rpart(
        AQI_p24 ~ .,
        data    = train_data %>% select(all_of(c(PARTITION_B, "AQI_p24"))),
        method  = "class",
        control = rpart.control(maxdepth = input$inp_tree_maxdepth, cp = input$inp_tree_cp,
                                minsplit = input$inp_tree_minsplit, minbucket = input$inp_tree_minbucket)
      )
      setProgress(0.3, detail = "Tree (balanced prior)...")
      tree_B_balanced <- rpart(
        AQI_p24 ~ .,
        data    = train_data %>% select(all_of(c(PARTITION_B, "AQI_p24"))),
        method  = "class",
        parms   = list(prior = c(0.25, 0.25, 0.25, 0.25)),
        control = rpart.control(maxdepth = input$inp_tree_maxdepth, cp = input$inp_tree_cp,
                                minsplit = input$inp_tree_minsplit, minbucket = input$inp_tree_minbucket)
      )
      setProgress(0.5, detail = "Depth sweep...")
      # RF predictions are optional — only computed when rf_B is available
      preds_rf_B_for_tree <- if (!is.null(m$rf_B)) predict_rf(m$rf_B, test_data, PARTITION_B)$preds else NULL
      actual_int          <- as.integer(test_data$AQI_p24)
      depth_sweep <- tibble(maxdepth = 2:12) %>%
        mutate(
          fit = map(maxdepth, ~ rpart(
            AQI_p24 ~ .,
            data    = train_data %>% select(all_of(c(PARTITION_B, "AQI_p24"))),
            method  = "class",
            control = rpart.control(maxdepth = .x, cp = input$inp_tree_cp,
                                    minsplit = input$inp_tree_minsplit, minbucket = input$inp_tree_minbucket)
          )),
          preds_tree = map(fit, ~ as.integer(
            predict(.x, newdata = test_data %>% select(all_of(PARTITION_B)), type = "class")
          )),
          agreement_rf = if (!is.null(preds_rf_B_for_tree))
                           map_dbl(preds_tree, ~ mean(.x == preds_rf_B_for_tree))
                         else
                           NA_real_,
          accuracy     = map_dbl(preds_tree, ~ mean(.x == actual_int)),
          n_leaves     = map_int(fit, ~ sum(.x$frame$var == "<leaf>"))
        ) %>%
        select(-fit, -preds_tree)
      setProgress(1.0)
      rv_sc4(list(
        tree_B              = tree_B,
        tree_B_balanced     = tree_B_balanced,
        depth_sweep         = depth_sweep,
        actual_int          = actual_int,
        preds_rf_B_for_tree = preds_rf_B_for_tree
      ))
    })
  })

  #  all_preds: builds predictions from whatever models are currently trained ─
  all_preds <- reactive({
    m <- rv_models()
    result <- list()
    if (!is.null(m$rf_A)) {
      result$p_rf_A <- predict_rf(m$rf_A, test_data, PARTITION_A)
      result$p_rf_B <- predict_rf(m$rf_B, test_data, PARTITION_B)
    }
    if (!is.null(m$xgb_A)) {
      result$p_xgb_A <- predict_xgb(m$xgb_A, m$dtest_A, test_data)
      result$p_xgb_B <- predict_xgb(m$xgb_B, m$dtest_B, test_data)
    }
    if (!is.null(m$knn_A)) {
      result$p_knn_A <- predict_knn(m$knn_A, test_data)
      result$p_knn_B <- predict_knn(m$knn_B, test_data)
    }
    if (!is.null(m$ordinal_A)) {
      result$p_ord_A <- predict_ordinal(m$ordinal_A, test_data, PARTITION_A)
      result$p_ord_B <- predict_ordinal(m$ordinal_B, test_data, PARTITION_B)
    }
    if (!is.null(m$partial_A)) {
      result$p_par_A <- predict_partial(m$partial_A, test_data, PARTITION_A)
    }
    if (!is.null(m$multinomial_A)) {
      result$p_mul_A <- predict_multinom(m$multinomial_A, test_data, PARTITION_A)
      result$p_mul_B <- predict_multinom(m$multinomial_B, test_data, PARTITION_B)
    }
    result
  })

  #  summaries: builds tables + PR curve from all available predictions 
  summaries <- reactive({
    p <- all_preds()
    if (length(p) == 0) return(NULL)
    m <- rv_models()

    # Specs for models with both A and B partitions
    ab_specs <- list(
      list(key_a = "p_rf_A",  key_b = "p_rf_B",  method = "Random Forest",    type = "Non-parametric"),
      list(key_a = "p_xgb_A", key_b = "p_xgb_B", method = "XGBoost",          type = "Non-parametric"),
      list(key_a = "p_knn_A", key_b = "p_knn_B", method = "kNN",              type = "Non-parametric"),
      list(key_a = "p_ord_A", key_b = "p_ord_B", method = "Ordinal Reg.",     type = "Parametric"),
      list(key_a = "p_mul_A", key_b = "p_mul_B", method = "Multinomial Reg.", type = "Parametric")
    )
    # Specs for partition-A-only models
    a_only_specs <- list(
      list(key = "p_par_A", method = "Partial PO", type = "Parametric")
    )

    metric_rows <- list()
    recall_rows <- list()
    for (spec in ab_specs) {
      if (!is.null(p[[spec$key_a]])) {
        metric_rows <- c(metric_rows, list(compute_metrics(p[[spec$key_a]]$preds, p[[spec$key_a]]$actual) %>% mutate(Method = spec$method, Type = spec$type, Partition = "A")))
        recall_rows <- c(recall_rows, list(compute_class_recall(p[[spec$key_a]]$preds, p[[spec$key_a]]$actual) %>% mutate(Method = spec$method, Type = spec$type, Partition = "A")))
      }
      if (!is.null(p[[spec$key_b]])) {
        metric_rows <- c(metric_rows, list(compute_metrics(p[[spec$key_b]]$preds, p[[spec$key_b]]$actual) %>% mutate(Method = spec$method, Type = spec$type, Partition = "B")))
        recall_rows <- c(recall_rows, list(compute_class_recall(p[[spec$key_b]]$preds, p[[spec$key_b]]$actual) %>% mutate(Method = spec$method, Type = spec$type, Partition = "B")))
      }
    }
    for (spec in a_only_specs) {
      if (!is.null(p[[spec$key]])) {
        metric_rows <- c(metric_rows, list(compute_metrics(p[[spec$key]]$preds, p[[spec$key]]$actual) %>% mutate(Method = spec$method, Type = spec$type, Partition = "A")))
        recall_rows <- c(recall_rows, list(compute_class_recall(p[[spec$key]]$preds, p[[spec$key]]$actual) %>% mutate(Method = spec$method, Type = spec$type, Partition = "A")))
      }
    }

    if (length(metric_rows) == 0) return(NULL)

    summary_table <- bind_rows(metric_rows) %>%
      select(Type, Method, Partition, everything()) %>%
      arrange(Type, Method, Partition)

    recall_long <- bind_rows(recall_rows) %>%
      mutate(
        Model     = paste0(Method, " (", Partition, ")"),
        AQI_Class = factor(Label, levels = aqi_levels)
      )

    # PR curve - only models that expose class probabilities
    actual_poor    <- as.integer(test_data$AQI_p24) == 4
    pr_models_list <- list()

    if (!is.null(m$rf_B_prob)) {
      pr_models_list[["RF B"]] <- PRROC::pr.curve(
        scores.class0  = predict(m$rf_B_prob, data = test_data)$predictions[, 4],
        weights.class0 = actual_poor, curve = TRUE)
    }
    if (!is.null(m$xgb_B)) {
      xgb_margins <- predict(m$xgb_B, m$dtest_B, outputmargin = TRUE, strict_shape = TRUE)
      xgb_exp     <- exp(xgb_margins)
      xgb_prob_B  <- xgb_exp / rowSums(xgb_exp)
      pr_models_list[["XGBoost B"]] <- PRROC::pr.curve(
        scores.class0  = xgb_prob_B[, 4],
        weights.class0 = actual_poor, curve = TRUE)
    }
    if (!is.null(m$multinomial_B)) {
      pr_models_list[["Multinomial B"]] <- PRROC::pr.curve(
        scores.class0  = predictvglm(m$multinomial_B, newdata = test_data %>% select(all_of(PARTITION_B)), type = "response")[, 4],
        weights.class0 = actual_poor, curve = TRUE)
    }
    if (!is.null(m$partial_A)) {
      pr_models_list[["Partial PO A"]] <- PRROC::pr.curve(
        scores.class0  = predictvglm(m$partial_A, newdata = test_data %>% select(all_of(PARTITION_A)), type = "response")[, 4],
        weights.class0 = actual_poor, curve = TRUE)
    }
    if (!is.null(m$ordinal_B)) {
      pr_models_list[["Ordinal Reg. B"]] <- PRROC::pr.curve(
        scores.class0  = predict(m$ordinal_B, newdata = test_data %>% select(all_of(PARTITION_B)), type = "probs")[, "4"],
        weights.class0 = actual_poor, curve = TRUE)
    }
    if (!is.null(m$knn_B)) {
      pr_models_list[["kNN B"]] <- PRROC::pr.curve(
        scores.class0  = m$knn_B$prob[, 4],
        weights.class0 = actual_poor, curve = TRUE)
    }

    pr_df <- if (length(pr_models_list) > 0) {
      pr_models_list %>%
        enframe(name = "name", value = "pr") %>%
        mutate(
          curve = map(pr, ~ as.data.frame(.x$curve) %>% setNames(c("recall", "precision", "threshold"))),
          auc   = map_dbl(pr, ~ .x$auc.integral)
        ) %>%
        unnest(curve) %>%
        mutate(model = paste0(name, "  (AUC=", round(auc, 3), ")"))
    } else {
      NULL
    }

    list(
      summary_table = summary_table,
      recall_long   = recall_long,
      pr_df         = pr_df,
      pr_prevalence = mean(actual_poor)
    )
  })

  #  Scenario 3 models (Lasso, Elastic Net, StepAIC) ─
  sc3_models <- eventReactive(input$btn_train_sc3, {
    withProgress(message = "Feature selection (Scenario 3)...", value = 0, {

      setProgress(0.2, detail = "Lasso CV...")
      set.seed(2026)
      cv_lasso <- cv.glmnet(
        as.matrix(train_data %>% select(all_of(PARTITION_B))),
        train_data$AQI_p24,
        family       = "multinomial",
        alpha        = LASSO_ALPHA,
        nfolds       = GLMNET_NFOLDS,
        weights      = compute_class_weights_multinomial(train_data, power = input$inp_mul_weight_power),
        type.measure = "class"
      )

      setProgress(0.5, detail = "Elastic Net CV...")
      set.seed(2026)
      cv_elnet <- cv.glmnet(
        as.matrix(train_data %>% select(all_of(PARTITION_B))),
        train_data$AQI_p24,
        family       = "multinomial",
        alpha        = ELNET_ALPHA,
        nfolds       = GLMNET_NFOLDS,
        weights      = compute_class_weights_multinomial(train_data, power = input$inp_mul_weight_power),
        type.measure = "class"
      )

      setProgress(0.8, detail = "Step backward...")
      # Refit vglm locally so step4vglm can resolve the data name in this scope
      train_subset <- train_data %>% select(all_of(c(PARTITION_B, "AQI_p24")))
      train_subset$AQI_p24 <- as.factor(as.character(train_subset$AQI_p24))
      multinom_B_local <- vglm(AQI_p24 ~ ., data = train_subset,
                               family  = multinomial(refLevel = 1),
                               model   = TRUE,
                               weights = compute_class_weights_multinomial(train_subset, power = input$inp_mul_weight_power))
      multinom_step_B <- step4vglm(multinom_B_local, direction = "backward")

      setProgress(1.0)
      list(cv_lasso = cv_lasso, cv_elnet = cv_elnet, multinom_step_B = multinom_step_B)
    })
  })

  #  Scenario 3 summary data 
  sc3_data <- reactive({
    s3 <- sc3_models()
    p  <- all_preds()

    test_mat   <- as.matrix(test_data %>% select(all_of(PARTITION_B)))
    actual_sc3 <- as.integer(as.character(test_data$AQI_p24))
    preds_lasso <- as.integer(predict(s3$cv_lasso, newx = test_mat, s = "lambda.1se", type = "class"))
    preds_elnet <- as.integer(predict(s3$cv_elnet, newx = test_mat, s = "lambda.1se", type = "class"))
    preds_step  <- predict_multinom(s3$multinom_step_B, test_data, PARTITION_B)$preds

    # Baseline (Multinomial B) only available when that model has been trained
    baseline_metrics <- if (!is.null(p$p_mul_B)) {
      compute_metrics(p$p_mul_B$preds, actual_sc3) %>% mutate(Method = "Multinomial B (baseline)")
    } else NULL

    sc3_metrics <- bind_rows(
      baseline_metrics,
      compute_metrics(preds_step,  actual_sc3) %>% mutate(Method = "StepAIC backward"),
      compute_metrics(preds_lasso, actual_sc3) %>% mutate(Method = "Lasso lambda.1se"),
      compute_metrics(preds_elnet, actual_sc3) %>% mutate(Method = "Elastic Net lambda.1se")
    ) %>% select(Method, everything())

    baseline_recall <- if (!is.null(p$p_mul_B)) {
      compute_class_recall(p$p_mul_B$preds, actual_sc3) %>% mutate(Method = "Multinomial B")
    } else NULL

    sc3_recall <- bind_rows(
      baseline_recall,
      compute_class_recall(preds_step,  actual_sc3) %>% mutate(Method = "StepAIC"),
      compute_class_recall(preds_lasso, actual_sc3) %>% mutate(Method = "Lasso"),
      compute_class_recall(preds_elnet, actual_sc3) %>% mutate(Method = "Elastic Net")
    ) %>% mutate(Label = factor(Label, levels = aqi_levels))

    kept_lasso_tbl <- extract_kept_features(s3$cv_lasso) %>% rename(Lasso_1se = kept)
    kept_elnet_tbl <- extract_kept_features(s3$cv_elnet) %>% rename(ElNet_1se = kept)

    feature_selection_table <- kept_lasso_tbl %>%
      left_join(kept_elnet_tbl, by = "feature") %>%
      mutate(
        StepAIC   = feature %in% attr(terms(s3$multinom_step_B), "term.labels"),
        Lasso_1se = replace_na(Lasso_1se, FALSE),
        ElNet_1se = replace_na(ElNet_1se, FALSE),
        StepAIC   = replace_na(StepAIC, FALSE),
        Kept      = as.integer(Lasso_1se) + as.integer(ElNet_1se) + as.integer(StepAIC)
      ) %>%
      arrange(desc(Kept), feature)

    list(
      sc3_metrics             = sc3_metrics,
      sc3_recall              = sc3_recall,
      feature_selection_table = feature_selection_table,
      cv_lasso                = s3$cv_lasso,
      cv_elnet                = s3$cv_elnet
    )
  })

  #  Tab 1: EDA plots 
  output$plot_ts <- renderPlot({
    complete_data %>%
      as_tibble() %>%
      mutate(Week = floor_date(Start, "week")) %>%
      group_by(Week) %>%
      summarise(AQI = mean(AQI, na.rm = TRUE), .groups = "drop") %>%
      ggplot(aes(Week, AQI)) +
      geom_line(color = "steelblue", linewidth = 0.4, alpha = 0.6) +
      geom_smooth(method = "loess", span = 0.1, se = FALSE, color = "firebrick", linewidth = 1) +
      scale_x_datetime(date_breaks = "1 year", date_labels = "%Y") +
      scale_y_continuous(breaks = 1:4, labels = aqi_levels, limits = c(1, 4)) +
      labs(title = "Weekly average AQI (2017-2024)",
           subtitle = "Red line = LOESS trend",
           x = NULL, y = "AQI level") +
      theme_minimal(base_size = 12)
  })

  output$plot_stl <- renderPlot({
    complete_data %>%
      as_tsibble(index = Start) %>%
      mutate(AQI = zoo::na.approx(AQI, na.rm = FALSE)) %>%
      model(STL(AQI ~ season("1 year") + season("1 week") + season("1 day"), robust = TRUE)) %>%
      components() %>%
      autoplot(linewidth = 0.4) +
      labs(title = "STL Decomposition of AQI (2017\u20132024)", x = NULL) +
      theme_minimal(base_size = 12) +
      theme(panel.grid.major = element_line(colour = "grey85"))
  })

  output$plot_dist <- renderPlot({
    model_features %>%
      count(AQI_t) %>%
      mutate(Label = factor(aqi_levels[AQI_t], levels = aqi_levels)) %>%
      ggplot(aes(Label, n, fill = Label)) +
      geom_col() +
      scale_fill_manual(values = aqi_colors) +
      scale_y_continuous(labels = scales::comma) +
      labs(x = NULL, y = "Hours") +
      theme_minimal() +
      theme(legend.position = "none")
  })

  output$plot_heatmap <- renderPlot({
    complete_data %>%
      as_tsibble(index = Start) %>%
      mutate(AQI = zoo::na.approx(AQI, na.rm = FALSE)) %>%
      index_by(Month = yearmonth(Start)) %>%
      summarise(AQI = mean(AQI, na.rm = TRUE), .groups = "drop") %>%
      gg_subseries(AQI) +
      scale_y_continuous(breaks = 1:4, labels = aqi_levels, limits = c(1, 4)) +
      labs(y = "Mean Monthly AQI", x = "Month",
           title = "Seasonal plot — monthly AQI by year (2017–2024)") +
      theme_minimal(base_size = 12)
  })

  output$plot_corr <- renderPlot({
    aqi_drivers %>%
      summarise(n = n(), .by = c(AQI, driver)) %>%
      mutate(pct = 100 * n / sum(n), .by = AQI) %>%
      mutate(
        driver = factor(driver, levels = c("PM2.5", "PM10", "NO2", "O3", "SO2", "Tie/Missing")),
        AQI    = factor(AQI, levels = 1:4, labels = aqi_levels)
      ) %>%
      ggplot(aes(AQI, pct, fill = driver)) +
      geom_col(width = 0.7) +
      geom_text(aes(label = if_else(pct >= 5, sprintf("%.0f%%", pct), "")),
                position = position_stack(vjust = 0.5), size = 3.2, color = "white", fontface = "bold") +
      scale_fill_manual(values = pollutant_colors) +
      scale_y_continuous(labels = scales::percent_format(scale = 1), expand = c(0, 0)) +
      labs(
        title = "Which pollutant drives the AQI? (by class)",
        x = "AQI class", y = "Share of hours (%)", fill = "Pollutant"
      ) +
      theme_minimal()
  })

  output$plot_boxplots <- renderPlot({
    model_features %>%
      select(AQI_t, PM25, PM10, NO2, O3, SO2) %>%
      mutate(AQI_Label = factor(aqi_levels[AQI_t], levels = aqi_levels)) %>%
      pivot_longer(c(PM25, PM10, NO2, O3, SO2), names_to = "Pollutant", values_to = "Value") %>%
      ggplot(aes(AQI_Label, Value, fill = AQI_Label)) +
      geom_boxplot(outlier.size = 0.5, outlier.alpha = 0.4) +
      facet_wrap(~ Pollutant, scales = "free_y", ncol = 5) +
      scale_fill_manual(values = aqi_colors) +
      labs(x = NULL, y = "µg/m³") +
      theme_minimal() +
      theme(legend.position = "none")
  })

  #  Tab 2: Model Comparison 
  selected_preds <- reactive({
    p    <- all_preds()
    model <- input$cmp_model
    part  <- if (grepl("A", input$cmp_partition)) "A" else "B"
    result <- if (model == "Random Forest") {
      if (part == "A") p$p_rf_A else p$p_rf_B
    } else if (model == "XGBoost") {
      if (part == "A") p$p_xgb_A else p$p_xgb_B
    } else if (model == "kNN") {
      if (part == "A") p$p_knn_A else p$p_knn_B
    } else if (model == "Ordinal Reg.") {
      if (part == "A") p$p_ord_A else p$p_ord_B
    } else if (model == "Partial PO") {
      p$p_par_A
    } else {
      if (part == "A") p$p_mul_A else p$p_mul_B
    }
    req(!is.null(result))
    result
  })

  output$tbl_summary <- renderTable({
    s <- summaries()
    req(!is.null(s))
    s$summary_table
  }, striped = TRUE, hover = TRUE, bordered = TRUE)

  output$plot_f1_bar <- renderPlot({
    s <- summaries()
    req(!is.null(s))
    summary_table <- s$summary_table
    method_order <- summary_table %>%
      group_by(Method) %>%
      summarise(best_f1 = max(`Macro F1`)) %>%
      arrange(best_f1) %>%
      pull(Method)
    summary_table %>%
      mutate(Method = factor(Method, levels = method_order)) %>%
      ggplot(aes(Method, `Macro F1`, fill = Partition)) +
      geom_col(position = position_dodge(0.7), width = 0.6) +
      geom_text(aes(label = sprintf("%.3f", `Macro F1`)),
                position = position_dodge(0.7), vjust = -0.4, size = 2.8) +
      scale_fill_brewer(palette = "Set2") +
      scale_y_continuous(limits = c(0, 0.56), expand = c(0, 0)) +
      facet_wrap(~ Type, scales = "free_x") +
      labs(y = "Macro F1", fill = "Partition") +
      theme_minimal() +
      theme(legend.position = "bottom", axis.text.x = element_text(angle = 25, hjust = 1))
  })

  output$plot_recall_heat <- renderPlot({
    s <- summaries()
    req(!is.null(s))
    recall_long <- s$recall_long
    model_order <- recall_long %>%
      filter(Label == "Poor") %>%
      arrange(Type, desc(`Recall (%)`)) %>%
      pull(Model)
    recall_long %>%
      mutate(Model = factor(Model, levels = rev(model_order))) %>%
      ggplot(aes(AQI_Class, Model, fill = `Recall (%)`)) +
      geom_tile(color = "white", linewidth = 0.5) +
      geom_text(aes(label = paste0(`Recall (%)`, "%")), size = 2.8) +
      scale_fill_distiller(palette = "RdYlGn", direction = 1, limits = c(0, 100)) +
      facet_wrap(~ Type, scales = "free_y", ncol = 1) +
      labs(x = "AQI Class", y = NULL, fill = "Recall (%)") +
      theme_minimal(base_size = 10)
  })

  output$plot_cm <- renderPlot({
    req(selected_preds())
    p <- selected_preds()
    mdl_name <- paste0(input$cmp_model, " (",
                       if (grepl("A", input$cmp_partition)) "A" else "B", ")")
    plot_confusion_matrix(p$actual, p$preds, mdl_name)
  })

  output$plot_imp <- renderPlot({
    m <- rv_models()
    req(!is.null(m$rf_B), !is.null(m$xgb_imp_perm_B))
    p_rf_imp  <- vip(m$rf_B, num_features = 22, geom = "col") +
      labs(title = "Random Forest B") + theme_minimal(base_size = 10)
    p_xgb_imp <- vip(m$xgb_imp_perm_B, num_features = 22, geom = "col") +
      labs(title = "XGBoost B") + theme_minimal(base_size = 10)
    p_rf_imp + p_xgb_imp +
      plot_annotation(title    = "Permutation Feature Importance (Partition B)")
  })

  output$plot_pr <- renderPlot({
    s <- summaries()
    req(!is.null(s), !is.null(s$pr_df))
    ggplot(s$pr_df, aes(recall, precision, color = model)) +
      geom_line(linewidth = 0.9) +
      geom_hline(yintercept = s$pr_prevalence, linetype = "dashed", color = "grey60") +
      annotate("text", x = 0.75, y = s$pr_prevalence + 0.03,
               label = paste0("Random baseline (", round(s$pr_prevalence * 100, 1), "%)"),
               size = 3, color = "grey50") +
      scale_color_brewer(palette = "Dark2") +
      scale_x_continuous(limits = c(0, 1)) +
      scale_y_continuous(limits = c(0, 1)) +
      labs(title = "One-vs-Rest Precision-Recall (Poor AQI Class)",
           x = "Recall", y = "Precision", color = "Model (PR-AUC)") +
      theme_minimal() +
      theme(legend.position = "bottom", legend.text = element_text(size = 8))
  })

  #  Tab 3: Scenario 3 
  output$tbl_sc3 <- renderTable({
    req(sc3_data())
    sc3_data()$sc3_metrics
  }, striped = TRUE, hover = TRUE)

  output$plot_sc3_recall <- renderPlot({
    req(sc3_data())
    sc3_data()$sc3_recall %>%
      ggplot(aes(Label, `Recall (%)`, fill = Method)) +
      geom_col(position = "dodge") +
      scale_fill_brewer(palette = "Set2") +
      labs(x = NULL, y = "Recall (%)") +
      theme_minimal() +
      theme(legend.position = "bottom")
  })

  output$tbl_sc3_features <- renderTable({
    req(sc3_data())
    sc3_data()$feature_selection_table %>%
      mutate(
        Lasso_1se = ifelse(Lasso_1se, "Y", "X"),
        ElNet_1se = ifelse(ElNet_1se, "Y", "X"),
        StepAIC   = ifelse(StepAIC, "Y", "X")
      )
  }, striped = TRUE, hover = TRUE)

  output$plot_lasso_cv <- renderPlot({
    req(sc3_data())
    cv_lasso <- sc3_data()$cv_lasso
    plot(cv_lasso)
    title("Lasso - CV misclassification vs. log(lambda)", line = 2.5)
  })

  output$plot_elnet_cv <- renderPlot({
    req(sc3_data())
    cv_elnet <- sc3_data()$cv_elnet
    plot(cv_elnet)
    title("Elastic Net - CV misclassification vs. log(lambda)", line = 2.5)
  })

  #  Tab 4: Scenario 4 
  output$plot_depth_sweep <- renderPlot({
    s4 <- rv_sc4()
    req(!is.null(s4))
    has_rf <- !all(is.na(s4$depth_sweep$agreement_rf))
    metrics_to_plot <- if (has_rf) c("agreement_rf", "accuracy") else "accuracy"
    s4$depth_sweep %>%
      pivot_longer(all_of(metrics_to_plot),
                   names_to = "metric", values_to = "value") %>%
      mutate(metric = dplyr::recode(metric,
                             agreement_rf = "Agreement with RF",
                             accuracy     = "Test accuracy")) %>%
      ggplot(aes(maxdepth, value * 100, color = metric)) +
      geom_line(linewidth = 1.2) +
      geom_point(size = 2.5) +
      geom_text(
      data = s4$depth_sweep %>%
          group_by(maxdepth) %>%
          summarise(n_leaves = first(n_leaves),
                    y = if (has_rf) max(agreement_rf, accuracy, na.rm = TRUE) * 100 + 1.5
                        else accuracy * 100 + 1.5),
        aes(maxdepth, y, label = paste0(n_leaves, "L")),
        color = "grey40", size = 3
      ) +
      scale_x_continuous(breaks = 2:12) +
      scale_color_manual(values = c("Agreement with RF" = "#2c7bb6",
                                    "Test accuracy"      = "#d7191c")) +
      labs(x = "Tree max depth", y = "(%)", color = NULL) +
      theme_minimal() +
      theme(legend.position = "bottom")
  })

  output$tbl_tree_metrics <- renderTable({
    s4 <- rv_sc4()
    req(!is.null(s4))
    p  <- all_preds()
    preds_tree_B   <- as.integer(predict(s4$tree_B,          newdata = test_data %>% select(all_of(PARTITION_B)), type = "class"))
    preds_tree_bal <- as.integer(predict(s4$tree_B_balanced, newdata = test_data %>% select(all_of(PARTITION_B)), type = "class"))
    rf_row <- if (!is.null(p$p_rf_B))
      compute_metrics(p$p_rf_B$preds, p$p_rf_B$actual) %>% mutate(Model = "RF B (weighted)")
    else NULL
    bind_rows(
      rf_row,
      compute_metrics(preds_tree_B,   s4$actual_int) %>% mutate(Model = "Tree (unweighted)"),
      compute_metrics(preds_tree_bal, s4$actual_int) %>% mutate(Model = "Tree (balanced prior)")
    ) %>% select(Model, everything())
  }, striped = TRUE)

  output$plot_tree <- renderPlot({
    s4 <- rv_sc4()
    req(!is.null(s4))
    use_balanced <- isTRUE(input$chk_tree_balanced)
    tree_to_show <- if (use_balanced) s4$tree_B_balanced else s4$tree_B
    tree_label   <- if (use_balanced) "balanced (weighted)" else "unweighted"
    rpart.plot(tree_to_show, type = 4, extra = 104,  box.palette = list("#50f0e6", "#50ccaa", "#f0e641", "#ff5050"),
               main = paste0("Decision Tree - Partition B (depth = 5, ", tree_label, ")"))
  })

  output$plot_tree_cm <- renderPlot({
    s4 <- rv_sc4()
    req(!is.null(s4))
    preds_tree_B <- as.integer(predict(s4$tree_B, newdata = test_data %>% select(all_of(PARTITION_B)), type = "class"))
    plot_confusion_matrix(s4$actual_int, preds_tree_B, "Confusion Matrix: Tree (unweighted)")
  })

  output$plot_tree_cm_bal <- renderPlot({
    s4 <- rv_sc4()
    req(!is.null(s4))
    preds_tree_bal <- as.integer(predict(s4$tree_B_balanced, newdata = test_data %>% select(all_of(PARTITION_B)), type = "class"))
    plot_confusion_matrix(s4$actual_int, preds_tree_bal, "Confusion Matrix: Tree (balanced prior)")
  })

  #  Tab 5: Prediction Lookup 
  prediction_results <- eventReactive(input$btn_predict, {
    m <- rv_models()
    req(!is.null(m$xgb_A))

    new_obs <- tibble(
      AQI_t   = input$inp_aqit,
      AQI_t1  = input$inp_aqit1,
      AQI_t2  = input$inp_aqit2,
      AQI_t24 = input$inp_aqit24,
      PM25    = input$inp_pm25,
      PM10    = input$inp_pm10,
      NO2     = input$inp_no2,
      O3      = input$inp_o3,
      SO2     = input$inp_so2,
      hour    = input$inp_hour,
      month   = input$inp_month
    )

    xgb_dm   <- xgb.DMatrix(as.matrix(new_obs %>% select(all_of(PARTITION_A))))
    xgb_pred <- as.integer(predict(m$xgb_A, xgb_dm)) + 1L

    tibble(
      `Predicted AQI (int)` = xgb_pred,
      `AQI Class`           = aqi_levels[xgb_pred]
    )
  })

  output$tbl_predictions <- renderTable({
    req(prediction_results())
    prediction_results()
  }, striped = TRUE, hover = TRUE)
}

shinyApp(ui, server)
