# Process Picarro data for CPCRW incubation
# This script produces a wide range of diagnostic and QC plots, of both the raw 
# and (clean) summary datasets. It doesn't change anything in the data pipeline.
# Ben Bond-Lamberty September 2015

source("R/0-functions.R")

SCRIPTNAME  	<- "3-qc.R"
PROBLEM       <- FALSE

# Main ===========================================================================

openlog(file.path(outputdir(), paste0(SCRIPTNAME, ".log.txt")), sink = TRUE) # open log

printlog("Welcome to", SCRIPTNAME)

printlog("Reading in summary data...")
summarydata <- read_csv(SUMMARYDATA_CLEAN_FILE)
print_dims(summarydata)

summarydata$DATETIME <- ymd_hms(summarydata$DATETIME)

# Basic diagnostics -------------------------------------------------------

printlog(SEPARATOR)
printlog("Number of samples for each core, by date:")
samples_by_date <- summarydata %>% 
  mutate(Date = strftime(DATETIME, format = "%Y-%m-%d", tz = "UTC")) %>% 
  group_by(Core, Date) %>% 
  summarise(n = n())
save_data(samples_by_date)
p <- qplot(Date, Core, data = samples_by_date, geom = "tile", fill = factor(n))
p <- p + theme(axis.text.x = element_text(angle = 90))
p <- p + ggtitle("Number of reps by date and core") + scale_fill_discrete("Reps")
save_diagnostic(p, "samples_by_date")

print(summarydata %>% group_by(Core) %>% summarise(n()) %>% as.data.frame())

summarydata %>%   # save a list of samples and corresponding cores
  select(DATETIME, MPVPosition, Core) %>% 
  save_data(fn = "samplelist.csv")

printlog("Summaries for max_CH4 and max_CO2:")
summary(summarydata$max_CO2)
summary(summarydata$max_CH4)

# Orphan samples & missing masses -----------------------------------------

printlog(SEPARATOR)
printlog("Checking for orphan samples...")
orphan_samples <- filter(summarydata, is.na(Core))
if(nrow(orphan_samples)) {
  printlog("NOTE:", nrow(orphan_samples), "samples have no matching core numbers")
  save_data(orphan_samples)
}
printlog("Visualizing orphan samples...")
p <- ggplot(summarydata, aes(DATETIME, MPVPosition, color=!is.na(Core), size=is.na(Core)))
p <- p + geom_jitter() 
p <- p + scale_color_manual("Has core number", values = c("TRUE" = "grey", "FALSE" = "red")) 
p <- p + scale_size_discrete(guide = FALSE)
p <- p + ggtitle("Orphan samples (no matching date/valve info)")
save_diagnostic(p, "orphan_samples")

p <- ggplot(subset(summarydata, Core != "Ambient4" & Core != "Ambient20"), 
            aes(DATETIME, Core, size = is.na(Mass_g), color = !is.na(Mass_g)))
p <- p + geom_point() 
p <- p + scale_color_manual("Has mass data", values = c("TRUE" = "grey", "FALSE" = "red"))
p <- p + scale_size_discrete(guide = FALSE)
p <- p + ggtitle("Missing mass data")
save_diagnostic(p, "missing_mass")

# --------------------- Compute uncorrected fluxes by date ---------------------

printlog(SEPARATOR)
printlog("Computing per-date summaries...")
summarydata <- summarydata %>%
  mutate(Date = strftime(DATETIME, format = "%Y-%m-%d"))

summarydata %>%
  group_by(Date, Treatment, Temperature) %>%
  summarise(CO2_ppm_s_sd = sd(CO2_ppm_s), CO2_ppm_s = mean(CO2_ppm_s),
            CH4_ppb_s_sd = sd(CH4_ppb_s), CH4_ppb_s = mean(CH4_ppb_s),
            Mass_g = mean(Mass_g),
            incday = as.numeric(round(mean(inctime_days), 0)),
            samplenums = paste(unique(samplenum), collapse = " ")) ->
  smry

treatment_summary <- smry
save_data(treatment_summary, scriptfolder = FALSE)

# --------------------- Core CVs ---------------------

# Peyton takes 2-3 measurements per core per day. Look at their variability
printlog(SEPARATOR)
printlog("Computing core CVs...")
core_cv <- summarydata %>% 
  filter(Core != "Ambient4" & Core != "Ambient20") %>%
  group_by(Date, Core) %>% 
  summarise(CO2_ppm_s_cv = sd(CO2_ppm_s) / mean(CO2_ppm_s),
            CH4_ppb_s_cv = sd(CH4_ppb_s) / mean(CH4_ppb_s),
            min_CO2_time = mean(min_CO2_time),
            max_CO2_time = mean(max_CO2_time),
            samplenums = paste(unique(samplenum), collapse = " ")) %>% 
  ungroup() %>% 
  arrange(desc(CO2_ppm_s_cv))

save_plot("CO2_core_cv", p = qplot(CO2_ppm_s_cv, data = core_cv, bins = 40))
save_plot("CH4_core_cv", p = qplot(CH4_ppb_s_cv, data = core_cv, bins = 40))

p <-  qplot(1:nrow(core_cv), CO2_ppm_s_cv, data = core_cv)
p <- p + ggtitle("Distribution of CO2 CV by core and date")
save_diagnostic(p, "coreCV_distribution")

core_cv <- core_cv[1:25,]    # only do this many detail plots

MAX_COMBINED_PLOTS <- 9

printlog("Reading in raw data...")
rawdata <- readr::read_csv(RAWDATA_SAMPLES_FILE, col_types = "ccddddcid")
rawdata$samplenum <- as.factor(rawdata$samplenum)
summarydata$samplenum <- as.factor(summarydata$samplenum)

# -----------------------------------------------------------------------------
# Per-core plots of computed concentration changes

printlog(SEPARATOR)
printlog("Per-core plots:")
rdata_final <- sdata_final <- data.frame()
for(i in seq_len(nrow(core_cv))) {
  samplenums <- strsplit(core_cv$samplenums[i], " ") %>% unlist
  rdata <- filter(rawdata, samplenum %in% samplenums)
  plot <- paste0("#", i, ": ", core_cv$Core[i], ", ", core_cv$Date[i])
  rdata$plot <- plot
  sdata <- filter(summarydata, samplenum %in% samplenums)
  sdata$plot <- plot
  p <- ggplot(rdata, aes(elapsed_seconds, CO2_dry, color=samplenum)) + geom_point()
  p <- p + geom_segment(data = sdata, aes(x = min_CO2_time, y = min_CO2, 
                                          xend = max_CO2_time, yend = max_CO2,
                                          color = samplenum), size = 5, alpha = 0.3)
  p <- p + ggtitle(paste(i, "Core", core_cv$Core[i], core_cv$Date[i], "CV =", round(core_cv$CO2_ppm_s_cv[i], 2)))
  
  if(i <= MAX_COMBINED_PLOTS) {
    rdata_final <- rbind(rdata_final, rdata)
    sdata_final <- rbind(sdata_final, sdata)
    save_diagnostic(p, paste0("coreCV_", i), printit = FALSE)
  } else {
    save_plot(paste0("coreCV_", i), p = p)
  }
}

# Combined plot
p <- ggplot(rdata_final, aes(elapsed_seconds, CO2_dry, color=samplenum)) + geom_point()
p <- p + geom_segment(data = sdata_final, aes(x = min_CO2_time, y = min_CO2, 
                                              xend = max_CO2_time, yend = max_CO2,
                                              color = samplenum), size = 5, alpha = 0.3)
p <- p + facet_wrap(~plot) + scale_color_discrete(guide = FALSE)
p <- p + ggtitle(paste(MAX_COMBINED_PLOTS, "most variable observations"))
save_diagnostic(p, "coreCV_combined")

# -----------------------------------------------------------------------------
# Flux rates and treatment CVs

printlog(SEPARATOR)
printlog("Flux rates and treatment CVs")

# Plot CV (coefficient of variability) by treatment and date
p <- qplot(paste(Temperature, Treatment), Date, fill = CO2_ppm_s_sd/CO2_ppm_s, 
           data = subset(smry, Treatment != "Ambient"), geom = "tile") + 
  scale_fill_continuous("CV") + 
  ggtitle("CV of CO2 observations by date")
save_diagnostic(p, "CO2_CV")
p <- qplot(paste(Temperature, Treatment), Date, fill = CH4_ppb_s_sd/CH4_ppb_s, 
           data = subset(smry, Treatment != "Ambient"), geom = "tile") + 
  scale_fill_continuous("CV") + 
  ggtitle("CV of CH4 observations by date")
save_diagnostic(p, "CH4_CV")

p <- qplot(Date, CO2_ppm_s, data = smry, color = CO2_ppm_s_sd/CO2_ppm_s) +
  geom_line(aes(group = paste(Temperature, Treatment)), color = "grey", linetype = 2) +
  geom_errorbar((aes(ymin = CO2_ppm_s-CO2_ppm_s_sd, ymax = CO2_ppm_s+CO2_ppm_s_sd))) +
  scale_color_continuous(guide = FALSE) + 
  facet_grid(Temperature~Treatment) + 
  theme(axis.text.x = element_text(angle = 90, hjust = 1)) +
  ggtitle("CO2 fluxes (ppm/s, uncorrected) by date")
save_diagnostic(p, "CO2_time")

p <- qplot(Date, CH4_ppb_s, data = smry, color = CH4_ppb_s_sd/CH4_ppb_s) +
  geom_line(aes(group = paste(Temperature, Treatment)), color = "grey", linetype = 2) +
  geom_errorbar((aes(ymin = CH4_ppb_s-CH4_ppb_s_sd, ymax = CH4_ppb_s+CH4_ppb_s_sd))) +
  scale_color_continuous(guide = FALSE) + 
  facet_grid(Temperature~Treatment) + 
  theme(axis.text.x = element_text(angle = 90, hjust = 1)) +
  ggtitle("CH4 fluxes (ppb/s, uncorrected) by date")
save_diagnostic(p, "CH4_time")

# -----------------------------------------------------------------------------
# Individual cores over time

printlog(SEPARATOR)
printlog("Individual cores over time")

# Reorder the 'Core' factor so that facets are ordered by Treatment and Temperature
summarydata$TT <- paste(summarydata$Treatment, summarydata$Temperature)
sd_no_A <- summarydata %>% 
  filter(Core != "Ambient4" & Core != "Ambient20") %>% 
  arrange(TT)
sd_no_A$Core <- factor(sd_no_A$Core, levels = unique(as.character(sd_no_A$Core)))
p <- qplot(inctime_days, CO2_ppm_s, data = sd_no_A, color = TT)
p <- p + ggtitle("CO2 fluxes (uncorrected) by rep, core, incubation day") + scale_color_discrete("")
p <- p + facet_wrap(~Core, ncol = 6)
print(p)
save_plot("CO2_incday")

p <- qplot(inctime_days, CH4_ppb_s, data = sd_no_A, color = paste(Treatment, Temperature))
p <- p + ggtitle("CH4 fluxes (uncorrected) by rep, core, incubation day") + scale_color_discrete("")
p <- p + facet_wrap(~Core, ncol = 6)
print(p)
save_plot("CH4_incday")

# -----------------------------------------------------------------------------
# Mass diagnostics

printlog(SEPARATOR)
printlog("Mass diagnostics")

p <- qplot(inctime_days, Mass_g, data = summarydata, geom = c("point", "line"), 
           group = Core, color = Treatment)
p <- p + ggtitle("Core masses, by incubation day and treatment") 

labeldata <- summarydata %>%
  group_by(Core, Treatment, Temperature) %>% 
  summarise(n = n() - floor(runif(1) * 6), # randomly position labels
            Mass_g = nth(Mass_g, n),
            inctime_days = nth(inctime_days, n))
labeldata$inctime_days <- labeldata$inctime_days - runif(nrow(labeldata)) * 4
p <- p + geom_text(data = labeldata, aes(label = Core), size = 4, show.legend = FALSE)
p <- p + scale_color_discrete("") + facet_grid(Temperature ~ .)
save_diagnostic(p, "masses")

summarydata <- summarydata %>%
  group_by(Core) %>% 
  arrange(inctime_days) %>%
  mutate(Mass_change = (Mass_g - first(Mass_g)) / Mass_g * 100)
p <- qplot(inctime_days, Mass_change, data = summarydata, geom = c("point", "line"), 
           group = Core, color = Treatment)
p <- p + ylab("Change (%)") 
p <- p + ggtitle("Core mass change, by incubation day and treatment") 
p <- p + facet_grid(~Temperature)
save_diagnostic(p, "masses_relative")

# -----------------------------------------------------------------------------
# Update README

# The README functions as a quick diagnostic summary on the webpage
printlog(SEPARATOR)
printlog("Updating README.md document...")
cmd <- paste0("sed -i .bak 's/^Latest data.*$/Latest data: ", max(smry$Date), 
              " (incubation day ", max(smry$incday), ")",
              "/' README.md")
print(cmd)
try(system(cmd))
cmd <- paste0("sed -i .bak 's/^Script run.*$/Script run: ", Sys.time(), "/' README.md")
print(cmd)
try(system(cmd))

# -----------------------------------------------------------------------------
# Done! 

printlog("All done with", SCRIPTNAME)
print(sessionInfo())
closelog()

if(PROBLEM) warning("There was a problem - see log")
