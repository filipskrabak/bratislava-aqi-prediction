# Predicting Bratislava AQI (Air Quality Index) with ML

This project analyzes weather and air pollution data from Bratislava, Mamateyova street 2017-2024, to predict AQI (Air Quality Index), focusing on **poor** conditions. Based on the findings, classifications with multiple algorithms are performed and the results are compared to each other, showcasing that the best models achieve much stronger predictive power than just simple baseline model (predicting same AQI as the day before). It is a time-series problem, which with feature engineering can be made as supervised learning problem, suitable for classic machine learning models.

The whole analysis can be seen in [project.md](/project.md)

## Features
- Merged two datasets
- Thorough EDA, with a lot of plots and detailed explanations
- Non-parametric models -> **Random Forest, XGBoost and kNN**
- Parametric models -> **Ordinal regression, Partial PO model and Multinomial regression**
- Feature selection -> **Lasso, Elastic Net and Backward step**
- **Decision tree visualization** based on best RF model 
- **Shiny app**

## Data
This project required two datasets that were merged together based on the timestamps.

Pollutants: [European Environment Agency (EEA) Air Quality Download Service](https://eeadmz1-downloads-webapp.azurewebsites.net/) <br>
Weather: [Open Meteo Historical Weather](https://open-meteo.com/en/docs/historical-weather-api)

## Results
**Baseline model performance** <br>
Baseline model was simply predicting same AQI as it was the day before.

| Metric          | Value |
|-----------------|-------|
| Macro F1        | 0.433 |
| Poor Recall (%) | 32.5  |

**Other models performance**
![](project_files/figure-gfm/unnamed-chunk-72-1.png)

| Method             | Macro F1 | Poor Rec |
|--------------------|----------|----------|
| Random Forest  | 0.467    | 49.7     |
| XGBoost        | 0.476    | 51.9     |
| kNN           | 0.369    | 11.4     |
| Ordinal Regression | 0.460 | 38.9   |
| Partial PO     | 0.386    | 67.3     |
| Multinomial Reg. | 0.455  | 58.0     |

## Getting started
The whole analysis can be seen [here](/project.md), on Github.
In case of local settings, this repo can be cloned and then run `project.Rmd` from beginning (dependency installation is included).  

## Project Table of Contents
- [Intro](/project.md#introduction)
- [EDA](/project.md#exploratory-data-analysis-eda)
- [Feature Engineering](/project.md#feature-engineering)
- [Models](/project.md#scenario-1-three-methods-across-two-feature-approaches--scenario-2-3-parametric-and-3-non-parametric-models)
    - [Random Forest](/project.md#random-forest)
    - [XGBoost](/project.md#xgboost)
    - [kNN](/project.md#k-nearest-neighbours-knn)
    - [Ordinal Regression](/project.md#ordinal-regression)
    - [Partial PO](/project.md#partial-proportional-odds)
    - [Multinomial Regression](/project.md#multinomial-regression)
- [Feature selection](/project.md#parameters)
- [Decision tree visualization](/project.md#decision-tree)
- [Conclusion](/project.md#conclusion)

## Shiny app
![](project_files/gifs/shiny1.gif)
![](project_files/gifs/shiny2.gif)
![](project_files/gifs/shiny3.gif)