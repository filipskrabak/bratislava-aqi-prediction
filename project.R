library(tidyverse)
library(arrow)
library(lubridate)
library(here)

clean_air_data <- open_dataset(here("pollutants")) %>%
  select(Start, Pollutant, Value, Samplingpoint) %>% # lazy loading
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
  # This takes the average of multiple stations! TODO: fix
  summarise(Value = mean(Value, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(
    names_from = Pollutant_Name, 
    values_from = Value
  ) %>%
  arrange(Start)

glimpse(clean_air_data)

View(clean_air_data)

## Weather

weather_file_path <- here("weather", "open-meteo-48.12N17.10E163m.csv")

weather_data <- read_csv(weather_file_path, skip = 3) %>%
  rename(
    Start = time,
    Temperature = `temperature_2m (°C)`,
    Rain = `rain (mm)`,
    Wind_Speed = `wind_speed_10m (km/h)`
  ) %>%
  select(Start, Temperature, Rain, Wind_Speed)

complete_data <- clean_air_data %>%
  inner_join(weather_data, by = "Start") %>%
  fill(where(is.numeric), .direction = "down")

glimpse(complete_data)
View(complete_data)
