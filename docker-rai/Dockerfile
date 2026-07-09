FROM rocker/shiny-verse:4.4.1

RUN R -e "options(repos=c(CRAN='https://cloud.r-project.org')); install.packages(c( \
    'bslib','readr','dplyr','caret','officer','flextable', 'randomForest' \
))"

COPY backend /srv/shiny-server/ares

RUN bash -lc 'printf "%s\n" "source(\"white.R\")" > /srv/shiny-server/ares/app.R' && \
    chown -R shiny:shiny /srv/shiny-server

ENV SHINY_LOG_STDERR=1 \
    SHINY_LOG_STDOUT=1 \
    TZ=Asia/Almaty

EXPOSE 3838
CMD ["/usr/bin/shiny-server"]
