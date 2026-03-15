library(tidyverse)
library(arrow)
library(lubridate)
library(here) # for handling paths correctly

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
  select(Start, Temperature, Rain, Wind_Speed) %>%
  filter(year(Start) >= 2017, year(Start) <= 2024)

complete_data <- clean_air_data %>%
  inner_join(weather_data, by = "Start")

glimpse(complete_data)
View(complete_data)

sum(complete.cases(complete_data))

# TODO: check time zones of both datasets (GMT vs GMT+1)