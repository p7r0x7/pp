#!/bin/sh

# SPDX-License-Identifier: Apache-2.0
# Copyright © 2025 @p7r0x7 <mattrbonnette@pm.me> All rights reserved.

#
#    VPXL's PP is an FFmpeg filterchain that optimizes the format and content of videos for encoding efficiency.
#    Only perceptible content is preserved (this filter is extremely conservative while remaining quite effective).
#    This filter should not be used on very low resolution content or prior to ultra high fidelity transcoding.
#

set -eu; umask 0022
ffprobe="$(command -v ffprobe) -v error"
placebo="libplacebo=dithering=none:sigmoid=0"
ffmpeg="$(command -v ffmpeg) -v error -hwaccel auto"

#convertcrop() {
#    IFS=:; set -- $crop; case $# in
#        2) printf 'crop_w=%s:crop_h=%s' "$@" ;;
#        4) printf 'crop_w=%s:crop_h=%s:crop_x=%s:crop_y=%s' "$@" ;;
#        *) printf 'Invalid crop format: %s\n' "$crop" >&2; return 1 ;;
#    esac
#}

isalpha() {
    fmts=$(awk 'BEGIN { ORS="|" } $3 == 2 || $3 == 4 { printf "%s", $2 }' /tmp/ffmpeg_fmts.txt)
    case "$fmt" in $fmts) return 0 ;; *) return 1 ;; esac
}

#isrgb() {
#    fmts=$(awk 'BEGIN { ORS="|" } $2 ~/r/ && $2 ~/g/ && $2 ~/b/ { printf "%s", $2 } END { printf "pal8" }' /tmp/ffmpeg_fmts.txt)
#    case "$fmt" in $fmts) return 0 ;; *) return 1 ;; esac
#}

subsampling() {
    case "$fmt" in
        gray*|mono*|ya*)                printf 400 ;;
        *410*)                          printf 410 ;;
        *411*)                          printf 411 ;;
        *420*|nv12|nv21|p0*)            printf 420 ;;
        *422*|nv16|nv20*|p2*|y2*|xv30*) printf 422 ;;
        *440*)                          printf 440 ;;
        *)                              printf 444 ;;
    esac
}

pp() {
    if [ ! -f /tmp/ffmpeg_fmts.txt ]; then $ffmpeg -pix_fmts >/tmp/ffmpeg_fmts.txt 2>&1 & fi
    eval "$(
        $ffprobe -select_streams v:0 -of default=nw=1:nk=1 "$video" \
            -show_entries stream=pix_fmt,color_space,color_transfer,color_primaries | awk \
            'NR==1 { printf "fmt=%s", $0 } NR==2 { printf "space=%s", $0 }
            NR==3 { printf "txfr=%s", $0 } NR==4 { printf "primes=%s", $0 }'
    )"
    [ $space = unknown ] && [ $txfr = unknown ] && [ $primes = unknown ] && space=bt709 txfr=bt709 primes=bt709
    wait; ss=$(subsampling)

    if isalpha "$video"; then alpha=1; else alpha=0; fi
    [ $alpha = 1 ] && fmt1=yuva444p16le fmt2=yuva420p10le || fmt1=yuv444p16le fmt2=yuv420p10le
    if [ $ss = 400 ]; then
        [ "$alpha" = 1 ] && fmt0="yap16le" || fmt0="grayp16le"
    elif [ $ss != 444 ]; then
        chroma_upscale="$placebo:format=$fmt1,"
        case $ss in
            410|411) fmt0="yuv${ss}p" ;; # alpha unavailable; 8-bit only
            440) fmt0=yuv440p12le ;;     # alpha unavailable; no 16-bit
            *) [ $alpha = 1 ] && fmt0="yuva${ss}p16le" || fmt0="yuv${ss}p16le" ;;
        esac
    else fmt0="$fmt1"; fi

    detelecine=""
    deinterlace="bwdif=mode=0:deint=1,"

    filterchain="
        $detelecine
        $deinterlace
        trim=$start:$end,
        crop=$crop,
        zscale=min=$space:tin=$txfr:pin=$primes:m=ictcp:t=smpte2084:p=bt2020,format=$fmt0,
        $chroma_upscale
        hqdn3d=1.0:0:0:0,
        yaepblur=s=6.0,
        bilateral=1,
        smartblur=lr=0.2:ls=-0.2,
        $placebo:deband=1:deband_radius=32:deband_iterations=8:deband_threshold=1.5:deband_grain=0,
        $placebo:format=$fmt2,
        zscale=min=ictcp:tin=smpte2084:pin=bt2020:m=$space:t=$txfr:p=$primes:r=tv,
        mpdecimate=hi=256:lo=64:frac=0.1,
        fps=fps=$fps:eof_action=pass"

    $ffmpeg -i "$video" -map 0:v -vf "$filterchain" -fps_mode cfr -c:v rawvideo -strict -1 -f yuv4mpegpipe -
}
#pp() {
#    crop=$1 fps=$2 video=$3; vspipe -c y4m -a crop="$crop" -a fps="$fps" -a video="$video" "${0%/*}"/pp.vpy -
#}

case $# in
    3) crop=$1 fps=$2 video=$3 ;;
    4) crop=$1 fps=$2 video=$3 start=$4 ;;
    5) crop=$1 fps=$2 video=$3 start=$4 end=$5 ;;
    *) printf "Usage: pp <crop w:h> <fps rational> <video> [start [end]]\n    Handles video streams only.\n" >&2; return 1 ;;
esac

pp
