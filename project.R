library(tidyverse)
library(arrow)
library(lubridate)
library(here) # for handling paths correctly
library(corrplot)
here::i_am("project.R")

# Description of this dataset is in docs/POLLUTANTS.md
pollutants_data <- open_dataset(here("pollutants"))

glimpse(pollutants_data)
# TODO: check variables, such as Validity, or AggType.

clean_air_data <- pollutants_data %>%
  select(Start, Pollutant, Value, Samplingpoint, Validity) %>% # lazy loading
  filter(grepl("SK0001A", Samplingpoint)) %>%
  filter(year(Start) >= 2017, year(Start) <= 2024) %>%
  collect() %>%
  # Translate EU codes into factors
  mutate(Pollutant_Name = case_when(
    Pollutant == 1 ~ "SO2",
    Pollutant == 5 ~ "PM10",
    Pollutant == 7 ~ "O3",
    Pollutant == 8 ~ "NO2",
    Pollutant == 10 ~ "CO",
    Pollutant == 6001 ~ "PM2.5",
    TRUE ~ as.character(Pollutant)
  )) %>%
  select(Start, Pollutant_Name, Value) %>%
  group_by(Start, Pollutant_Name) %>%
  summarise(Value = mean(Value, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(
    names_from = Pollutant_Name, 
    values_from = Value
  ) %>%
  arrange(Start)

glimpse(clean_air_data)

View(clean_air_data)

sum(complete.cases(clean_air_data)) # 60845
nrow(clean_air_data) # 69718

## Weather

weather_file_path <- here("weather", "open-meteo-48.12N17.10E163m.csv")

# TODO: select more variables, reason about which ones
weather_data <- read_csv(weather_file_path, skip = 3) %>%
  rename(
    Start = time,
    Temperature = `temperature_2m (°C)`,
    Rain = `rain (mm)`,
    Wind_Speed = `wind_speed_10m (km/h)`
  ) %>%
  #select(Start, Temperature, Rain, Wind_Speed) %>%
  filter(year(Start) >= 2017, year(Start) <= 2024)

complete_data <- clean_air_data %>%
  inner_join(weather_data, by = "Start")

glimpse(complete_data)
View(complete_data)

sum(complete.cases(complete_data))

# TODO: check time zones of both datasets (GMT vs GMT+1)

## European AQI
add_eaqi <- function(df) {
  df %>%
    mutate(
      AQI_PM2.5 = case_when(
        `PM2.5` <=   5 ~ 1L, `PM2.5` <=  15 ~ 2L, `PM2.5` <=  50 ~ 3L,
        `PM2.5` <=  90 ~ 4L, `PM2.5` <= 140 ~ 5L, `PM2.5` >  140 ~ 6L
      ),
      AQI_PM10 = case_when(
        PM10 <=  15 ~ 1L, PM10 <=  45 ~ 2L, PM10 <= 120 ~ 3L,
        PM10 <= 195 ~ 4L, PM10 <= 270 ~ 5L, PM10 >  270 ~ 6L
      ),
      AQI_O3 = case_when(
        O3 <=  60 ~ 1L, O3 <= 100 ~ 2L, O3 <= 120 ~ 3L,
        O3 <= 160 ~ 4L, O3 <= 180 ~ 5L, O3 >  180 ~ 6L
      ),
      AQI_NO2 = case_when(
        NO2 <=  10 ~ 1L, NO2 <=  25 ~ 2L, NO2 <=  60 ~ 3L,
        NO2 <= 100 ~ 4L, NO2 <= 150 ~ 5L, NO2 >  150 ~ 6L
      ),
      AQI_SO2 = case_when(
        SO2 <=  20 ~ 1L, SO2 <=  40 ~ 2L, SO2 <= 125 ~ 3L,
        SO2 <= 190 ~ 4L, SO2 <= 275 ~ 5L, SO2 >  275 ~ 6L
      ),
      AQI = pmax(AQI_PM2.5, AQI_PM10, AQI_O3, AQI_NO2, AQI_SO2, na.rm = TRUE),
      AQI_Label = case_when(
        AQI == 1L ~ "Good",
        AQI == 2L ~ "Fair",
        AQI == 3L ~ "Moderate",
        AQI == 4L ~ "Poor",
        AQI == 5L ~ "Very poor",
        AQI == 6L ~ "Extremely poor"
      )
    )
}

complete_data <- add_eaqi(complete_data)
glimpse(complete_data)

## AQI seasonal trends 2017–2024
aqi_levels <- c("Good", "Fair", "Moderate", "Poor", "Very poor", "Extremely poor")
aqi_colors <- c("Good"           = "#50f0e6",
                "Fair"           = "#50ccaa",
                "Moderate"       = "#f0e641",
                "Poor"           = "#ff5050",
                "Very poor"      = "#960032",
                "Extremely poor" = "#7d2181")

complete_data %>%
  mutate(
    Week = floor_date(Start, "week"),
    AQI_Label = factor(AQI_Label, levels = aqi_levels)
  ) %>%
  group_by(Week) %>%
  summarise(AQI = mean(AQI, na.rm = TRUE), .groups = "drop") %>%
  ggplot(aes(x = Week, y = AQI)) +
  geom_line(color = "steelblue", linewidth = 0.4, alpha = 0.6) +
  geom_smooth(method = "loess", span = 0.08, se = FALSE, color = "firebrick", linewidth = 1) +
  scale_x_datetime(date_breaks = "1 year", date_labels = "%Y") +
  scale_y_continuous(
    breaks = 1:6,
    labels = aqi_levels,
    limits = c(1, 6)
  ) +
  labs(
    title = "Weekly average AQI (2017–2024)",
    subtitle = "Red line = LOESS trend",
    x = NULL, y = "AQI level"
  ) +
  theme_minimal()

## Correlation heatmap – all numeric variables
complete_data %>%
  select(where(is.numeric)) %>%
  drop_na() %>%
  cor() %>%
  corrplot(
    method   = "color",
    type     = "upper",
    addCoef.col = "black",
    number.cex  = 0.7,
    tl.col   = "black",
    tl.srt   = 45,
    col      = COL2("RdBu", 200),
    title    = "Correlation matrix: all variables",
    mar      = c(0, 0, 1.5, 0)
  )

## Wind Speed vs PM10
complete_data %>%
  drop_na(Wind_Speed, PM10) %>%
  ggplot(aes(x = Wind_Speed, y = PM10)) +
  geom_point(alpha = 0.1, color = "steelblue") +
  geom_smooth(method = "gam", color = "firebrick", linewidth = 1) +
  labs(
    title    = "Non-linear impact of wind speed on PM10",
    subtitle = "Bratislava air quality (2017–2024)",
    x        = "Wind speed (km/h)",
    y        = "PM10 concentration (µg/m³)"
  ) +
  theme_minimal()
