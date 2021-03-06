  ## script needs file for country and country population.
  library(tidyverse)
  library(readxl)
  library(httr)
  # create data twitter survey data
  survey_twitter_esp <- data.frame(date = c("2020/03/14", "2020/03/16", "2020/03/18"), 
                                   survey_twitter = c((374.05/(762*150))* 46754778, (66.13/(85*150))*46754778,
                                              (116.16/(120*150))*46754778), stringsAsFactors = F)
  
  # create data twitter survey data
  survey_twitter_pt <- data.frame(date = c("2020/03/18", "2020/03/20"), 
                                   survey_twitter = c((11/(63*150))*10261075, 15/(45*150)*10261075),
                                  stringsAsFactors = F)
  
  
  
  hosp_to_death_trunc <- function(x, mu_hdt, sigma_hdt){
    dlnorm(x, mu_hdt, sigma_hdt)
  }
  # Functions from https://cmmid.github.io/topics/covid19/severity/global_cfr_estimates.html
  # Hospitalisation to death distribution
  
  # Function to work out correction CFR
  scale_cfr <- function(data_1_in, delay_fun, mu_hdt, sigma_hdt){
    case_incidence <- data_1_in$cases
    death_incidence <- data_1_in$deaths
    cumulative_known_t <- 0 # cumulative cases with known outcome at time tt
    # Sum over cases up to time tt
    for(ii in 1:length(case_incidence)){
      known_i <- 0 # number of cases with known outcome at time ii
      for(jj in 0:(ii - 1)){
        known_jj <- (case_incidence[ii - jj]*delay_fun(jj, mu_hdt = mu_hdt, sigma_hdt = sigma_hdt))
        known_i <- known_i + known_jj
      }
      cumulative_known_t <- cumulative_known_t + known_i # Tally cumulative known
    }
    # naive CFR value
    b_tt <- sum(death_incidence)/sum(case_incidence) 
    # corrected CFR estimator
    p_tt <- sum(death_incidence)/cumulative_known_t
    data.frame(nCFR = b_tt, cCFR = p_tt, total_deaths = sum(death_incidence), 
               cum_known_t = round(cumulative_known_t), total_cases = sum(case_incidence))
  }
  calculate_ci <- function(p_est, level, pop_size) {
    z <- qnorm(level+(1-level)/2)
    se <- sqrt(p_est*(1-p_est))/sqrt(pop_size)
    return(list(low=p_est-z*se, upp=p_est+z*se, error=z*se))
  }
  get_countries_with_survey <- function(path = "../data/aggregate/"){
    #get list of countries with surveys
    plotdata_files <- list.files(path)
    plotdata_files <- plotdata_files[plotdata_files != "Twitter-surveys.csv"]
    substr(plotdata_files,start = 1, stop = 2)
  }
  
  estimate_cases_aggregate <- function(file_path,
                                       country_population,
                                       batch,
                                       method = c("antonio", "carlos"),
                                       max_ratio,
                                       correction_factor) {
    #cat("file_path is ", file_path, "\n")
    #cat("country_population is", country_population, "\n")
    dt <- read.csv(file_path, as.is = T)
    names(dt) <- c("timestamp","region","reach","cases")
    dt$date <- substr(dt$timestamp, 1, 10)
    n_inital_response <- nrow(dt)
    
    # remove outliers from reach column
    reach_cutoff <- boxplot.stats(dt$reach)$stats[5] # changed cutoff to upper fence
    if(sum(dt$reach > reach_cutoff) > 0 ){
      # write.table(dt[dt$reach >= reach_cutoff, ],
      #             file = paste0("outliers_removed/", file_name, "_", "outliers_reach.txt"),
      #              append = T) # write out outliers from reach column to the ouliers removed folder
      n_reach_outliers <- sum(dt$reach > reach_cutoff) #number of outliers removed based on reach
      dt <- dt[dt$reach <= reach_cutoff, ]
    }else{
      n_reach_outliers <- 0
    }
    
    # remove outliers based on max ratio of   0.3
    dt$ratio <- dt$cases/dt$reach
    dt2 <- dt[is.finite(dt$ratio), ]  # discard cases with zero reach
    n_zero_reach_outliers <- sum(!is.finite(dt$ratio)) 
    if(sum(dt2$ratio > max_ratio) > 0 ){
      #write.table(dt[dt$ratio >= max_ratio, ],
      #            file = paste0("outliers_removed/", file_name, "_", "outliers_max_ratio.txt"),
      #            append = T) # write out outliers based on max_Ratio
      n_maxratio_outliers <- sum(dt2$ratio > max_ratio) 
      dt2 <- dt2[dt2$ratio <= max_ratio, ]
    }else{
      n_maxratio_outliers <- 0
    }
    
    
    method <- match.arg(method)
    
    if (method == "antonio"){
      dt_batch <- dt2 %>%
        group_by(date) %>% 
        summarise(sample_size = n())
      # generate grouping variable: if number of responses in a day is sufficient, then agg that day, if not agg multiple days
      group = 1
      group_factor = c()
      container <- c()
      
      for (i in 1:nrow(dt_batch)) {
        container <- c(container, dt_batch$sample_size[i])
        if(sum(container) < batch){
          group_factor <- c(group_factor, group)
        } else{
          group_factor <- c(group_factor, group)
          container <- c()
          group = group + 1
        }
      }
      dt_batch$group_factor <- group_factor
      
      dt_batch_s <- dt_batch %>% 
        group_by(group_factor) %>%
        summarise(n = sum(sample_size)) 
      dt_batch_s$include <- dt_batch_s$n >= batch
      
      dt_batch <- full_join(dt_batch, dt_batch_s, by = "group_factor") %>% 
        filter(include == T)
      
      dt2 <- full_join(dt2, dt_batch[,-c(2, 4,5)], by = "date")
      dt_summary <- dt2 %>%
        filter(!is.na(group_factor)) %>% 
        group_by(group_factor) %>% 
        summarise(date = last(date),
                  sample_size = n(), 
                  mean_cases = mean(cases),
                  mean_reach = mean(reach),
                  dunbar_reach = 150 * n(),
                  cases_p_reach = sum(cases)/sum(reach), 
                  cases_p_reach_low = calculate_ci(p_est = sum(cases)/sum(reach), level = 0.95,
                                                   pop_size = sum(reach))$low,
                  cases_p_reach_high = calculate_ci(p_est = sum(cases)/sum(reach), level=0.95,
                                                    pop_size = sum(reach))$upp,
                  cases_p_reach_error = calculate_ci(p_est = sum(cases)/sum(reach), level=0.95,
                                                     pop_size = sum(reach))$error,
                  cases_p_reach_prop = mean(ratio), 
                  cases_p_reach_prop_median = median(ratio),
                  estimated_cases = country_population * sum(cases)/sum(reach) * correction_factor, 
                  estimate_cases_low = calculate_ci(p_est = sum(cases)/sum(reach), level = 0.95,
                                                    pop_size = sum(reach))$low *  country_population * correction_factor,
                  estimate_cases_high = calculate_ci(p_est = sum(cases)/sum(reach), level=0.95,
                                                     pop_size = sum(reach))$upp *  country_population * correction_factor,
                  estimate_cases_error = calculate_ci(p_est = sum(cases)/sum(reach), level=0.95,
                                                      pop_size = sum(reach))$error *  country_population * correction_factor,
                  prop_cases = country_population * mean(ratio) * correction_factor,
                  dunbar_cases = country_population * (sum(cases)/dunbar_reach) * correction_factor)
      dt_summary <- dt_summary[, -1] # remove group factor variable
    } else if (method == "carlos"){
      max_group <- nrow(dt2)/batch
      group_factor <- rep(1:floor(max_group), each = batch)
      group_factor <- c(group_factor, rep(NA, times = nrow(dt2) - length(group_factor)))
      dt2$group <- group_factor 
      
      dt_summary <- dt2 %>%
        filter(!is.na(group)) %>% 
        group_by(group) %>% 
        summarise(date = last(date),
                  sample_size = n(),
                  mean_cases = mean(cases),
                  mean_reach = mean(reach),
                  dunbar_reach = 150 * n(),
                  cases_p_reach = sum(cases)/sum(reach), 
                  cases_p_reach_low = calculate_ci(p_est = sum(cases)/sum(reach), level = 0.95,
                                                   pop_size = sum(reach))$low,
                  cases_p_reach_high = calculate_ci(p_est = sum(cases)/sum(reach), level=0.95,
                                                    pop_size = sum(reach))$upp,
                  cases_p_reach_error = calculate_ci(p_est = sum(cases)/sum(reach), level=0.95,
                                                     pop_size = sum(reach))$error,
                  cases_p_reach_prop = mean(ratio), 
                  cases_p_reach_prop_median = median(ratio),
                  estimated_cases = country_population * sum(cases)/sum(reach) * correction_factor, 
                  estimate_cases_low = calculate_ci(p_est = sum(cases)/sum(reach), level = 0.95,
                                                    pop_size = sum(reach))$low *  country_population * correction_factor,
                  estimate_cases_high = calculate_ci(p_est = sum(cases)/sum(reach), level=0.95,
                                                     pop_size = sum(reach))$upp *  country_population * correction_factor,
                  estimate_cases_error = calculate_ci(p_est = sum(cases)/sum(reach), level=0.95,
                                                      pop_size = sum(reach))$error *  country_population * correction_factor,
                  prop_cases = country_population * mean(ratio) * correction_factor,
                  dunbar_cases = country_population * (sum(cases)/dunbar_reach) * correction_factor) %>% 
        group_by(date) %>% 
        summarise(sample_size = mean(sample_size),
                  mean_cases = mean(mean_cases),
                  mean_reach = mean(mean_reach),
                  dunbar_reach = mean(dunbar_reach),
                  cases_p_reach = mean(cases_p_reach), 
                  cases_p_reach_low = mean(cases_p_reach_low),
                  cases_p_reach_high = mean(cases_p_reach_high),
                  cases_p_reach_error = mean(cases_p_reach_error),
                  cases_p_reach_prop = mean(cases_p_reach_prop), 
                  cases_p_reach_prop_median = mean(cases_p_reach_prop_median),
                  estimated_cases = mean(estimated_cases),
                  estimate_cases_low = mean(estimate_cases_low),
                  estimate_cases_high = mean(estimate_cases_high),
                  estimate_cases_error = mean(estimate_cases_error),
                  prop_cases = mean(prop_cases),
                  dunbar_cases = mean(dunbar_cases))
    } else{
      stop("method can only be antonio or carlos")
    }
  
   return(list(dt_estimates = dt_summary,
               n_inital_response = n_inital_response,
               n_reach_outliers = n_reach_outliers,
               n_maxratio_outliers = n_maxratio_outliers, 
               n_zero_reach_outliers = n_zero_reach_outliers,
               n_final_response = sum(dt_summary$sample_size)))
   
  }
  
  
  plot_estimates <- function(country_geoid = "NA", 
                             batch_size = 30,
                             batching_method = "antonio",
                             est_date = format(Sys.time(), "%Y-%m-%d"),
                             max_ratio = .3,
                             correction_factor = 1, 
                             z_mean_hdt = 13,
                             z_sd_hdt = 12.7,
                             z_median_hdt = 9.1,
                             c_cfr_baseline = 1.38,
                             c_cfr_estimate_range = c(1.23, 1.53), 
                             survey_countries =  get_countries_with_survey()){
    mu_hdt = log(z_median_hdt)
    sigma_hdt = sqrt(2*(log(z_mean_hdt) - mu_hdt))
    cat("Downloading ecdc data for ",country_geoid ,"....\n")
    url <- paste("https://www.ecdc.europa.eu/sites/default/files/documents/COVID-19-geographic-disbtribution-worldwide-",
                 est_date, ".xlsx", sep = "")
    GET(url, authenticate(":", ":", type="ntlm"), write_disk(tf <- tempfile(fileext = ".xlsx")))
    data <- read_excel(tf)
    
    data_country_code <- read_excel("wikipedia-iso-country-codes.xlsx")
    names(data_country_code) <- c("English.short.name.lower.case", "Alpha.2.code",
                                  "Alpha.3.code", "Numeric.code", "ISO.3166.2")
    data <- inner_join(data, data_country_code, by = c("countryterritoryCode" = "Alpha.3.code")) %>% 
      select(dateRep:popData2018, "Alpha.2.code" )
    data$geoId <- data$Alpha.2.code 
    data <- data %>% select(dateRep:popData2018)
    cat("....downloaded successfully!\n")
    if(country_geoid %in% survey_countries){
      cat(country_geoid, "has a survey data file..", "reading survey data...", "\n")
      file_path = paste0("../data/aggregate/", country_geoid, "-aggregate.csv")
      cat("..read successfully! \n")
      data <- data[data$geoId == country_geoid,]
      dt <- data[rev(1:nrow(data)),]
      dt$cum_cases <- cumsum(dt$cases)
      dt$cum_deaths <- cumsum(dt$deaths)
      dt$cum_deaths_400 <- dt$cum_deaths * 400
      dt$date <- gsub("-", "/", dt$dateRep)
      ndt <- nrow(dt)
      est_ccfr <- rep(NA, ndt)
      cat("computing ccfr estimate for ", country_geoid, "...\n")
      for (i in ndt : 1) {
        data2t <- dt[1:i, c("cases", "deaths")]
        ccfr <- scale_cfr(data2t, delay_fun = hosp_to_death_trunc, mu_hdt = mu_hdt, sigma_hdt = sigma_hdt)
        fraction_reported <- c_cfr_baseline / (ccfr$cCFR*100)
        est_ccfr[i] <- dt$cum_cases[i]*1/fraction_reported
      }
      cat("ccfr estimate computed successfuly!...\n")
      cat("computing various estimates from survey data for ", country_geoid, "...\n")
      survey_gforms_estimate <- estimate_cases_aggregate(file_path = file_path,
                                                         country_population = dt$popData2018[1],
                                                         max_ratio = max_ratio,
                                                         correction_factor = correction_factor, 
                                                         method = batching_method,
                                                         batch = batch_size)$dt_estimates
      cat("combining ccfr and various estimates for", country_geoid, "...\n")
      
      dt$est_ccfr <- est_ccfr
      # combine dt and survey forms estimates
      dt_res <- full_join(dt, survey_gforms_estimate, by = "date")
      # combine with survey twitter
      if (country_geoid == "ES"){
        cat(country_geoid, "has twitter data...adding twitter estimates..\n")
        dt_res <- full_join(dt_res, survey_twitter_esp, by = "date") %>% 
          select(countriesAndTerritories, geoId, date, cases, deaths, cum_cases, cum_deaths, cum_deaths_400, est_ccfr, sample_size:survey_twitter)
        
      } else if(country_geoid == "PT"){
        cat(country_geoid, "has twitter data...adding twitter estimates..\n")
        dt_res <- full_join(dt_res, survey_twitter_pt, by = "date") %>% 
          select(countriesAndTerritories, geoId, date, cases, deaths, cum_cases, cum_deaths, cum_deaths_400, est_ccfr, sample_size:survey_twitter)
      } else{
        cat(country_geoid, "does not have twitter data....selecting relevant variables..\n")
        dt_res <- dt_res %>% 
          select(countriesAndTerritories, geoId, date, cases, deaths, cum_cases, cum_deaths, cum_deaths_400, est_ccfr, sample_size:dunbar_cases)
      }
      cat("attempting to write estimates data for ", country_geoid, "..\n")
      write.csv(dt_res, paste0("../data/PlotData/", country_geoid, "-", "estimates.csv"))
      cat("estimates data for ", country_geoid, "saved successfully..\n")
    } else{
      cat(country_geoid, "does not have a survey data file..", "\n")
      data <- data[data$geoId == country_geoid,]
      data_ecdc <- data_ecdc[data_ecdc$geoId == country_geoid,]
      dt <- data[rev(1:nrow(data)),]
      dt$cum_cases <- cumsum(dt$cases)
      dt$cum_deaths <- cumsum(dt$deaths)
      dt$cum_deaths_400 <- dt$cum_deaths * 400
      dt$date <- gsub("-", "/", dt$dateRep)
      ndt <- nrow(dt)
      est_ccfr <- rep(NA, ndt)
      cat("computing ccfr estimate for ", country_geoid, "...\n")
      for (i in ndt : 1) {
        data2t <- dt[1:i, c("cases", "deaths")]
        ccfr <- scale_cfr(data2t, delay_fun = hosp_to_death_trunc, mu_hdt = mu_hdt, sigma_hdt = sigma_hdt)
        fraction_reported <- c_cfr_baseline / (ccfr$cCFR*100)
        est_ccfr[i] <- dt$cum_cases[i]*1/fraction_reported
      }
      cat("ccfr estimate computed successfuly!...\n")
      cat("generating dummy data of various estimates for ", country_geoid, "...\n")
      survey_gforms_estimate <- data.frame(date = dt$date,
                                           sample_size = NA,
                                           mean_cases = NA,
                                           mean_reach = NA,
                                           dunbar_reach = NA,
                                           cases_p_reach = NA,
                                           cases_p_reach_low = NA,
                                           cases_p_reach_high = NA,
                                           cases_p_reach_error = NA,
                                           cases_p_reach_prop = NA,
                                           cases_p_reach_prop_median = NA,
                                           estimated_cases = NA,
                                           estimate_cases_low = NA,
                                           estimate_cases_high = NA,
                                           estimate_cases_error = NA,
                                           prop_cases = NA,
                                           dunbar_cases = NA,
                                          stringsAsFactors = F)
      cat("combining ccfr and various estimates for", country_geoid, "...\n")
      dt$est_ccfr <- est_ccfr
      # combine dt and survey forms estimates
      dt_res <- full_join(dt, survey_gforms_estimate, by = "date")
      cat(country_geoid, "selecting relevant variables...\n")
      dt_res <- dt_res %>% 
        select(countriesAndTerritories, geoId, date, cases, deaths, cum_cases, cum_deaths, cum_deaths_400, est_ccfr, sample_size:dunbar_cases)
      cat("attempting to write estimates data for ", country_geoid, "..\n")
      write.csv(dt_res, paste0("../data/PlotData/", country_geoid, "-", "estimates.csv"))
      cat("estimates data for ", country_geoid, "saved successfully..\n")
    }
    
  }
  
  
  # generate data for all countries
  url <- paste("https://www.ecdc.europa.eu/sites/default/files/documents/COVID-19-geographic-disbtribution-worldwide-",
               format(Sys.time(), "%Y-%m-%d"), ".xlsx", sep = "")
  GET(url, authenticate(":", ":", type="ntlm"), write_disk(tf <- tempfile(fileext = ".xlsx")))
  data_ecdc <- read_excel(tf)
  data_country_code <- read_excel("wikipedia-iso-country-codes.xlsx")
  names(data_country_code) <- c("English.short.name.lower.case", "Alpha.2.code",
                                "Alpha.3.code", "Numeric.code", "ISO.3166.2")
  
  data_ecdc <- inner_join(data_ecdc, data_country_code, by = c("countryterritoryCode" = "Alpha.3.code"))
  all_geo_ids <- unique(data_ecdc$Alpha.2.code)
  sapply(all_geo_ids, plot_estimates)
  
  
  
# # usage...generate and write data to plotdata folder
# # Spain
# plot_estimates(country_geoid = "ES", est_date = "2020-04-05")
# # Portugal
# plot_estimates(country_geoid = "PT", country_population = 10261075, 
#                est_date = "2020-04-05")
# 
# # Cyprus
# plot_estimates(country_geoid = "CY", country_population = 890900,
#                est_date = "2020-04-05")
# 
# # France
# plot_estimates(country_geoid = "FR", country_population = 66987244,
#                est_date = "2020-04-05")
# # Argentina
# plot_estimates(country_geoid = "AR", country_population = 45195774,
#                est_date = "2020-04-05")
# # Chile
# plot_estimates(country_geoid = "CL", country_population = 19116201,
#                est_date = "2020-04-05")
# #Germany
# plot_estimates(country_geoid = "DE", country_population = 83783942,
#                est_date = "2020-04-05")
# # Ecuador
# plot_estimates(country_geoid = "EC", country_population = 17643054,
#                est_date = "2020-04-05")
# #GB
# plot_estimates(country_geoid = "GB", country_population = 67886011,
#                est_date = "2020-04-05")
# 
# plot_estimates(country_geoid = "IT", country_population = 60461826,
#                est_date = "2020-04-05")
# 
# plot_estimates(country_geoid = "JP", country_population = 126476461,
#                est_date = "2020-04-05")
# 
# 
# plot_estimates(country_geoid = "NL", country_population = 17134872,
#                est_date = "2020-04-05")
# 
# plot_estimates(country_geoid = "US", country_population = 331002651,
#                est_date = "2020-04-05")
