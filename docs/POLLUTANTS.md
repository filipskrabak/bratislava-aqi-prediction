The Parquet files contain the most relevant information reported by the countries. In
the files various attributes can be found and are shown below:

- Samplingpoint: Identifier known as “local id” of the sampling point. Has the
country code prefix. This identifier is unique to each station and created by
national reporters, therefore there is no vocabulary for this parameter.

- Pollutant: The pollutant identifier. Find more information in this link:
https://dd.eionet.europa.eu/vocabulary/aq/pollutant

- Start: Beginning of the time interval in which the information has been reported.
Format: yyyy-mm-dd H:M:S

- End: End of the time interval in which the information has been reported.
Format: yyyy-mm-dd H:M:S

- Value: Numerical value that represents the measurement obtained for that
pollutant in that time interval.

- Unit: Unit in which the measurement obtained is represented. Find more
information in this link:

https://dd.eionet.europa.eu/vocabulary/uom/concentration
- AggType: This is the primary observation used in the measurement
and can be hour/day/var. It represents whether the data collected is
obtaining the values in hourly, daily or variable intervals (intervals
different than the previous observation such as weekly, monthly,
etc.). Find more information in this link:
https://dd.eionet.europa.eu/vocabulary/aq/primaryObservation

- Validity: Represents the validity of the measurement reported for the
specific pollutant within a specified time interval. Find more information in
this link:
https://dd.eionet.europa.eu/vocabulary/aq/observationvalidity

- Verification: Represents the verification status of the measurement reported
for that pollutant in that time interval. Find more information in this link:
https://dd.eionet.europa.eu/vocabulary/aq/observationverification

- ResultTime: Represents the date and time in which the information of
the file that contained the reported data was generated.

- DataCapture: The data capture associated with a primary observation.
Percentage of the time for which a sample or observation has been taken.

- FkObservationLog: This column has no importance for the end user. This is a column
for internal use.