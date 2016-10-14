package Project03;

import java.time.LocalDate;
import java.time.Period;
import java.util.Arrays;
import java.util.Calendar;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map.Entry;

public class BErrorChecker {

    private LinkedHashMap<String, Individual> individualMap;
    private LinkedHashMap<String, Family> familyMap;

    public BErrorChecker(LinkedHashMap<String, Individual> individualMap, LinkedHashMap<String, Family> familyMap){
        this.individualMap = individualMap;
        this.familyMap = familyMap;
    }
    
    public void check(){
    	checkUS07();
    	checkUS08();
    	checkUS10();
    }

    public void checkUS07(){
        for(Entry<String, Individual> indiMap: this.individualMap.entrySet()){
    		Individual indi = indiMap.getValue();
    		if(!indi.isUnder150YearsOld())
    			System.out.println("Anomaly US07: " + indi.name + "(" + indi.id + ")" + "'s age exceeds 150 years.");
    	}
    }

    private List<LocalDate> findParentMarriageAndDivorceDate(Individual indi){
        for(Entry<String, Family> familyEntry: familyMap.entrySet()){
            Family family = familyEntry.getValue();
            if(family.child.contains(indi.id)){
                Calendar calMarriage = Calendar.getInstance();
                calMarriage.setTime(family.marriageDate);
                LocalDate marriageDate = LocalDate.of(calMarriage.get(Calendar.YEAR), calMarriage.get(Calendar.MONTH)+1, calMarriage.get(Calendar.DATE));
                LocalDate divorceDate = null;
                if(family.divorceDate != null){
                    Calendar calDivorce = Calendar.getInstance();
                    calDivorce.setTime(family.divorceDate);
                    divorceDate = LocalDate.of(calDivorce.get(Calendar.YEAR), calDivorce.get(Calendar.MONTH)+1, calDivorce.get(Calendar.DATE));
                }

                return Arrays.asList(marriageDate, divorceDate);
            }
        }
        return Arrays.asList(null, null);
    }

    public void checkUS08(){
        for(Entry<String, Individual> indiEntry: individualMap.entrySet()){
            Individual indi = indiEntry.getValue();
            Calendar cal = Calendar.getInstance();
            cal.setTime(indi.birthDate);
            LocalDate indiBirthLocal = LocalDate.of(cal.get(Calendar.YEAR), cal.get(Calendar.MONTH)+1, cal.get(Calendar.DATE));
            List<LocalDate> marriageAndDivorceDate = findParentMarriageAndDivorceDate(indi);
            LocalDate parentMarriageDate = marriageAndDivorceDate.get(0);
            LocalDate parentDivorceDate = marriageAndDivorceDate.get(1);
            if(parentMarriageDate == null && parentDivorceDate == null)
                continue;

            Period childBirthAndParentMarriage = Period.between(parentMarriageDate, indiBirthLocal);
            if(childBirthAndParentMarriage.isNegative()){
                System.out.println("Anomaly US08: " + indi.name + "(" + indi.id + ")" + "'s birth " + Math.abs(childBirthAndParentMarriage.getYears()) + " year(s) before parents' merriage.");
                break;
            }
            if(parentDivorceDate == null)
                continue;
            Period childBirthAndParentDivorce = Period.between(indiBirthLocal, parentDivorceDate);
            if(childBirthAndParentDivorce.isNegative()){
                System.out.println("Anomaly US08: " + indi.name + "(" + indi.id + ")" + "'s birth after parents' divorce.");
            }
        }
    }
    
    public void checkUS10(){
    	String husbandId;
    	String wifeId;
    	Individual husband;
    	Individual wife;
    	for(Entry<String, Family> famEntry: this.familyMap.entrySet()){
    		husbandId = famEntry.getValue().husband;
    		wifeId = famEntry.getValue().wife;
    		husband = individualMap.get(husbandId);
    		wife = individualMap.get(wifeId);
    		Calendar calHusband = Calendar.getInstance();
    		calHusband.setTime(husband.birthDate);
    		Calendar calWife = Calendar.getInstance();
    		calWife.setTime(wife.birthDate);
    		LocalDate husbandBirthLocalDate = LocalDate.of(calHusband.get(Calendar.YEAR), calHusband.get(Calendar.MONTH)+1, calHusband.get(Calendar.DATE));
    		LocalDate wifeBirthLocalDate = LocalDate.of(calWife.get(Calendar.YEAR), calWife.get(Calendar.MONTH)+1, calWife.get(Calendar.DATE));

    		boolean isHusbandUnder14 = Period.between(husbandBirthLocalDate, LocalDate.now().minusYears(14)).isNegative();
    		boolean isWifeUnder14 = Period.between(wifeBirthLocalDate, LocalDate.now().minusYears(14)).isNegative();
    		
    		if(isHusbandUnder14 || isWifeUnder14){
    			System.out.printf("Error US10: One(or two) of the spouses from this family(%1s) are under 14 years old.\n", famEntry.getKey() );
    		}
    	}
    }

}
