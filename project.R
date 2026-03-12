library(tidyverse)
library(arrow)
library(lubridate)

folder_path <- "C:/Users/Filip/Downloads/ParquetFiles(2)/E2a"

file_list <- list.files(path = folder_path, pattern = "\\.parquet$", full.names = TRUE)

raw_air_data <- file_list %>%
  map_dfr(read_parquet)

View(raw_air_data)

clean_air_data <- raw_air_data %>%
  select(Start, Pollutant, Value, Samplingpoint) %>%
  
  mutate(Start = ymd_hms(Start)) %>%

  # Translate EU codes 
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
  summarise(Value = mean(Value, na.rm = TRUE)) %>%
  
  pivot_wider(
    names_from = Pollutant_Name, 
    values_from = Value
  ) %>%
  
  arrange(Start)

glimpse(clean_air_data)

View(clean_air_data)


## Weather

weather_file_path <- "C:/Users/Filip/Downloads/ParquetFiles(2)/E2a/open-meteo-48.12N17.10E163m.csv" 

weather_data <- read_csv(weather_file_path, skip = 3) %>%
  
  mutate(Start = ymd_hm(time)) %>%
  
  rename(
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
